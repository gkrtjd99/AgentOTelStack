#!/bin/sh
set -eu
ROOT=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)

usage(){
  echo "usage: $0 [--version X.Y.Z] archive.tar.gz [archive.tar.gz.sha256]" >&2
  exit 2
}
fail(){ echo "release source: $*" >&2; exit 1; }

expected=${RELEASE_EXPECTED_VERSION:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--expected-version)
      [ "$#" -ge 2 ] || usage
      expected=$2
      shift 2
      ;;
    --help) usage;;
    -*) usage;;
    *) break;;
  esac
done
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  usage
fi
archive=$1
checksum=${2:-${archive}.sha256}
if [ "$#" -eq 3 ]; then
  [ -z "$expected" ] || [ "$expected" = "$3" ] || usage
  expected=$3
fi
[ -f "$archive" ] || fail "archive not found: $archive"
[ -f "$checksum" ] || fail "checksum not found: $checksum"

base=${archive##*/}
case "$base" in
  AgentOTelStack-v*.tar.gz) ;;
  *) fail "invalid archive name: $base";;
esac
tag_version=${base#AgentOTelStack-v}
tag_version=${tag_version%.tar.gz}
case "$tag_version" in
  ''|*[!0-9.]*|*.*.*.*|.*|*.|*..*) fail "invalid archive version: $tag_version";;
esac
case "$tag_version" in
  *.*.*) :;;
  *) fail "invalid archive version: $tag_version";;
esac
major=${tag_version%%.*}
version_tail=${tag_version#*.}
minor=${version_tail%%.*}
patch_version=${version_tail#*.}
case "$major:$minor:$patch_version" in
  0[0-9]*:*|*:0[0-9]*:*|*:*:0[0-9]*) fail "invalid archive version: $tag_version";;
esac
[ -z "$expected" ] || [ "$expected" = "$tag_version" ] || fail "archive version $tag_version does not match expected $expected"

hash_file(){
  file=$1
  line=''
  digest=''
  if command -v sha256sum >/dev/null 2>&1; then
    line=$(sha256sum "$file") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    line=$(shasum -a 256 "$file") || return 1
  else
    echo 'neither sha256sum nor shasum is available' >&2
    return 1
  fi
  digest=${line%%[[:space:]]*}
  printf '%s' "$digest" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  printf '%s\n' "$digest"
}
actual_hash=$(hash_file "$archive") || fail 'unable to calculate archive checksum'
line=$(sed -n '1p' "$checksum")
line_count=$(wc -l < "$checksum" | tr -d '[:space:]')
[ "$line_count" = 1 ] || fail 'checksum must contain exactly one line'
[ "$line" = "$actual_hash  $base" ] || fail 'checksum mismatch or checksum is not basename-only'

root_name="AgentOTelStack-v${tag_version}"
max_entries=${RELEASE_MAX_ARCHIVE_ENTRIES:-20000}
max_uncompressed=${RELEASE_MAX_ARCHIVE_BYTES:-209715200}
max_entry=${RELEASE_MAX_ENTRY_BYTES:-52428800}
max_logical=${RELEASE_MAX_LOGICAL_BYTES:-$max_uncompressed}
for archive_limit in "$max_entries" "$max_uncompressed" "$max_entry" "$max_logical"; do
  case "$archive_limit" in ''|*[!0-9]*) fail 'archive limits must be non-negative integers';; esac
done
listing=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-listing.XXXXXX")
verbose=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-mode.XXXXXX")
extract=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release-extract.XXXXXX")
cleanup(){
  rm -f "$listing" "$verbose"
  [ -z "${symlinks:-}" ] || rm -f "$symlinks"
  [ -z "${gzip_stream:-}" ] || rm -f "$gzip_stream"
  rm -rf "$extract"
}
trap cleanup EXIT HUP INT TERM

# Python's standard gzip reader is already an existing project/CI dependency
# (the JSON gates use python3) and is portable on supported macOS/Linux hosts.
# Read at most limit+1 decompressed bytes first. We only reach EOF, and thus
# complete gzip CRC validation, after the stream is proven within the cap; a
# bomb is rejected without an unbounded `gzip -t` or full materialization.
gzip_stream=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-stream.XXXXXX")
if ! python3 - "$archive" "$gzip_stream" "$max_uncompressed" <<'PY'
import gzip
import pathlib
import sys

source, destination, limit_text = sys.argv[1:]
limit = int(limit_text)
total = 0
try:
    with gzip.open(source, "rb") as stream, pathlib.Path(destination).open("wb") as output:
        while True:
            chunk = stream.read(min(1024 * 1024, limit + 1 - total))
            if not chunk:
                # EOF is intentionally required for a within-limit stream so
                # gzip.GzipFile verifies its footer CRC and trailer.
                break
            output.write(chunk)
            total += len(chunk)
            if total > limit:
                print(f"archive exceeds uncompressed size limit: {total} > {limit}", file=sys.stderr)
                raise SystemExit(3)
except (OSError, EOFError, gzip.BadGzipFile) as error:
    print(f"archive gzip stream is invalid: {error}", file=sys.stderr)
    raise SystemExit(4)
PY
then
  fail 'bounded gzip preflight failed'
fi
uncompressed_bytes=$(wc -c < "$gzip_stream" | tr -d '[:space:]')
[ "$uncompressed_bytes" -le "$max_uncompressed" ] || fail "archive exceeds uncompressed size limit: $uncompressed_bytes > $max_uncompressed"

# Inspect tar metadata before extraction. tarfile is standard-library-only and
# lets us reject PAX/GNU sparse metadata and logical-size amplification that a
# byte-size cap alone cannot represent.
if ! python3 - "$gzip_stream" "$root_name" "$max_entries" "$max_entry" "$max_logical" <<'PY'
import pathlib
import posixpath
import sys
import tarfile

stream_path, root_name, max_entries_text, max_entry_text, max_logical_text = sys.argv[1:]
max_entries = int(max_entries_text)
max_entry = int(max_entry_text)
max_logical = int(max_logical_text)
count = 0
logical = 0

def safe_path(name):
    if not name or not (name == root_name or name.startswith(root_name + "/")):
        raise SystemExit(f"archive entry is outside expected root: {name}")
    relative = name[len(root_name):].lstrip("/")
    if not relative:
        return
    if any(part in {"", ".", ".."} for part in relative.split("/")) or "\\" in relative or ":" in relative:
        raise SystemExit(f"unsafe archive path: {name}")

def safe_link(target):
    if not target or target.startswith("/") or "\\" in target or ":" in target:
        raise SystemExit(f"unsafe archive symlink target: {target}")
    if any(part in {"", ".", ".."} for part in target.split("/")):
        raise SystemExit(f"unsafe archive symlink target: {target}")

try:
    with pathlib.Path(stream_path).open("rb") as handle, tarfile.open(fileobj=handle, mode="r:") as archive:
        for member in archive:
            count += 1
            if count > max_entries:
                raise SystemExit(f"archive exceeds entry count limit: {count} > {max_entries}")
            safe_path(member.name)
            pax = {str(key).lower() for key in member.pax_headers}
            if getattr(member, "sparse", None) or member.type == getattr(tarfile, "GNUTYPE_SPARSE", b"?") or any("sparse" in key for key in pax):
                raise SystemExit(f"sparse tar entry is forbidden: {member.name}")
            if member.size < 0:
                raise SystemExit(f"negative tar entry size: {member.name}")
            if member.size > max_entry:
                raise SystemExit(f"archive entry exceeds logical size limit: {member.name}: {member.size} > {max_entry}")
            logical += member.size
            if logical > max_logical:
                raise SystemExit(f"archive exceeds cumulative logical size limit: {logical} > {max_logical}")
            if member.isdir():
                continue
            if member.isreg():
                continue
            if member.issym():
                safe_link(member.linkname)
                continue
            raise SystemExit(f"unsupported or special archive entry: {member.name}")
except (tarfile.TarError, OSError) as error:
    print(f"unable to inspect tar metadata: {error}", file=sys.stderr)
    raise SystemExit(5)
PY
then
  fail 'archive metadata validation failed'
fi

tar -tf "$gzip_stream" > "$listing" 2>/dev/null || fail 'archive is not a readable tar stream'
tar -tvf "$gzip_stream" > "$verbose" 2>/dev/null || fail 'unable to inspect archive entry modes'
entry_count=$(wc -l < "$listing" | tr -d '[:space:]')
[ "$entry_count" -le "$max_entries" ] || fail "archive exceeds entry count limit: $entry_count > $max_entries"

seen_root=false
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    "$root_name"|"$root_name"/) seen_root=true;;
    "$root_name"/*)
      relative=${entry#"$root_name"/}
      case "$relative" in
        */) relative=${relative%/};;
      esac
      case "/$relative/" in
        */../*|*/./*|*//*|*\\*|*:*) fail "unsafe archive path: $entry";;
      esac
      [ -n "$relative" ] || fail "empty archive path"
      ;;
    *) fail "archive entry is outside expected root: $entry";;
  esac
done < "$listing"
[ "$seen_root" = true ] || fail "archive root is missing: $root_name/"
python3 - "$ROOT" "$listing" "$root_name" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
listing = pathlib.Path(sys.argv[2])
root_name = sys.argv[3]
sys.path.insert(0, str(root / "scripts"))
import release_source_policy as policy

for entry in listing.read_text().splitlines():
    if entry == root_name or entry == root_name + "/":
        continue
    if not entry.startswith(root_name + "/"):
        continue
    relative = entry[len(root_name) + 1:]
    if relative.endswith("/"):
        relative = relative[:-1]
    diagnostic = policy.diagnostic(relative, tracked=False)
    if diagnostic:
        raise SystemExit(diagnostic.replace("secret-like path is forbidden", "secret-like path is forbidden in archive"))
PY

# Symlinks are allowed only when their relative target cannot escape the
# archive root.  Rejecting unsafe links before extraction prevents a link from
# redirecting a later file entry out of the archive root.
while IFS= read -r mode_line; do
  mode=${mode_line%% *}
  case "$mode" in
    d*) :;;
    l*)
      link_target=${mode_line##* -> }
      case "$link_target" in
        ''|/*|*\\*|*:) fail "unsafe archive symlink target: $link_target";;
      esac
      case "/$link_target/" in
        */../*|*/./*|*//*|*\\*|*:*) fail "unsafe archive symlink target: $link_target";;
      esac
      ;;
    -*)
      case "$mode" in
        *[sStT]*) fail "special permission bits are forbidden: $mode_line";;
      esac
      ;;
    *) fail "symlink or unsupported archive entry mode: $mode_line";;
  esac
done < "$verbose"

if tar -xf /dev/null -C "$extract" --no-same-owner --no-same-permissions >/dev/null 2>&1; then
  tar -xf "$gzip_stream" -C "$extract" --no-same-owner --no-same-permissions || fail 'unable to extract archive for validation'
else
  tar -xf "$gzip_stream" -C "$extract" || fail 'unable to extract archive for validation'
fi
[ -d "$extract/$root_name" ] || fail "archive root is not a directory: $root_name"
[ ! -L "$extract/$root_name" ] || fail 'archive root is a symlink'

if find "$extract/$root_name" ! -type f ! -type d ! -type l -print -quit | grep -q .; then
  fail 'archive contains an unsupported filesystem entry'
fi
symlinks=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-symlinks.XXXXXX")
find "$extract/$root_name" -type l -print > "$symlinks"
while IFS= read -r link_path; do
  [ -n "$link_path" ] || continue
  link_target=$(readlink "$link_path")
  case "$link_target" in
    ''|/*|*\\*|*:) fail "unsafe extracted symlink: $link_path -> $link_target";;
  esac
  case "/$link_target/" in
    */../*|*/./*|*//*|*\\*|*:*) fail "unsafe extracted symlink: $link_path -> $link_target";;
  esac
  [ -e "$link_path" ] || fail "dangling extracted symlink: $link_path"
done < "$symlinks"
rm -f "$symlinks"

required='VERSION LICENSE README.md CHANGELOG.md docs/README.md docs/ko/README.md docs/AGENT_SETUP.md docs/ARCHITECTURE.md docs/CONNECT.md docs/DASHBOARD.md docs/DEVELOPMENT.md docs/JSON_CONTRACT.md docs/OPERATIONS.md docs/QUERY.md docs/RELEASING.md docs/REPLACE_SAMPLE_APP.md docs/SAMPLING_AND_COMPLETENESS.md docs/SECURITY.md docs/TROUBLESHOOTING.md docs/ko/AGENT_SETUP.md docs/ko/ARCHITECTURE.md docs/ko/CONNECT.md docs/ko/DASHBOARD.md docs/ko/DEVELOPMENT.md docs/ko/JSON_CONTRACT.md docs/ko/OPERATIONS.md docs/ko/QUERY.md docs/ko/RELEASING.md docs/ko/REPLACE_SAMPLE_APP.md docs/ko/SAMPLING_AND_COMPLETENESS.md docs/ko/SECURITY.md docs/ko/TROUBLESHOOTING.md VERSION LICENSE README.md CHANGELOG.md .env.example docker-compose.yml bin/obs scripts/install.sh scripts/uninstall.sh scripts/release_source_policy.py libexec/agentotel/dispatch.sh src/app/Dockerfile src/app/package.json src/app/package-lock.json src/backend-health/Dockerfile.collector src/dashboard/Dockerfile src/dashboard/LICENSE src/dashboard/go.mod src/dashboard/README.md src/dashboard/cmd/dashboard/main.go src/dashboard/cmd/dashboard/main_test.go src/dashboard/internal/proxy/proxy.go src/dashboard/internal/proxy/proxy_test.go src/dashboard/internal/ui/ui.go src/dashboard/internal/ui/ui_test.go src/dashboard/internal/ui/app_state_test.js src/dashboard/internal/ui/static/index.html src/dashboard/internal/ui/static/assets/app.js src/dashboard/internal/ui/static/assets/request-state.js src/dashboard/internal/ui/static/assets/styles.css src/backend-health/Dockerfile.victorialogs src/backend-health/Dockerfile.victoriametrics src/backend-health/Dockerfile.victoriatraces src/backend-health/health.go src/gateway/Dockerfile src/gateway/go.mod src/gateway/cmd/gateway/main.go src/gateway/internal/query/query.go src/gateway/internal/query/client.go src/gateway/internal/query/correlation/correlation.go src/gateway/internal/status/status.go src/gateway/schemas/context.schema.json src/gateway/schemas/correlate-v1.json src/gateway/schemas/correlate.schema.json src/gateway/schemas/envelope.schema.json src/gateway/schemas/errors.schema.json src/gateway/schemas/services.schema.json src/mcp/go.mod src/mcp/main.go src/otel-collector/config.yaml'
for path in $required; do
  [ -f "$extract/$root_name/$path" ] || fail "required release file is missing: $path"
  [ ! -L "$extract/$root_name/$path" ] || fail "required release file is a symlink: $path"
done
cmp -s "$extract/$root_name/LICENSE" "$extract/$root_name/src/dashboard/LICENSE" \
  || fail 'src/dashboard/LICENSE must exactly match LICENSE'

while IFS= read -r path; do
  [ -n "$path" ] || continue
  relative=${path#"$root_name"/}
  case "$relative" in
    .env.example|*/.env.example) :;;
    .github|.github/*|*/.github|*/.github/*|.env|*/.env|.env.*|*/.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.crt|*.cer|credentials|credentials/*|*/credentials|*/credentials/*|secrets|secrets/*|*/secrets|*/secrets/*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*|.aws|.aws/*|*/.aws|*/.aws/*|.kube|.kube/*|*/.kube|*/.kube/*|.agentotel|.agentotel/*|*/.agentotel|*/.agentotel/*|.git|.git/*|*/.git|*/.git/*|*/node_modules|*/node_modules/*|node_modules|node_modules/*|.cache|.cache/*|*/.cache|*/.cache/*|.trivy-cache|.trivy-cache/*|artifacts|artifacts/*|*/artifacts|*/artifacts/*|coverage|coverage/*|*/coverage|*/coverage/*|manifest.sha256|*/manifest.sha256|*.log|*.out|*.prof|*.test|*.coverage|bin/agentotel-mcp|bin/agentotel-mcp-*|src/mcp/mcp|src/*/bin/*)
      fail "forbidden generated output is present: $relative";;
  esac
done < "$listing"

version_file=$(cat "$extract/$root_name/VERSION")
[ "$version_file" = "$tag_version" ] || fail "archive VERSION is $version_file, expected $tag_version"

echo "verified $archive"
