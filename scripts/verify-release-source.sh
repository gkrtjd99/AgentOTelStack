#!/bin/sh
set -eu

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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo 'neither sha256sum nor shasum is available' >&2
    return 1
  fi
}
actual_hash=$(hash_file "$archive") || fail 'unable to calculate archive checksum'
line=$(sed -n '1p' "$checksum")
line_count=$(wc -l < "$checksum" | tr -d '[:space:]')
[ "$line_count" = 1 ] || fail 'checksum must contain exactly one line'
[ "$line" = "$actual_hash  $base" ] || fail 'checksum mismatch or checksum is not basename-only'

root_name="AgentOTelStack-v${tag_version}"
max_entries=${RELEASE_MAX_ARCHIVE_ENTRIES:-20000}
max_uncompressed=${RELEASE_MAX_ARCHIVE_BYTES:-209715200}
case "$max_entries" in ''|*[!0-9]*) fail 'archive limits must be non-negative integers';; esac
case "$max_uncompressed" in ''|*[!0-9]*) fail 'archive limits must be non-negative integers';; esac
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

gzip -t "$archive" >/dev/null 2>&1 || fail 'archive gzip stream is invalid'
gzip_stream=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-stream.XXXXXX")
max_probe=$(printf '%s\n' "$max_uncompressed" | awk '
  {
    carry=1; result=""
    for (i=length($0); i>0; i--) {
      digit=substr($0, i, 1)
      if (carry) {
        if (digit == "9") digit="0"
        else { digit=digit + 1; carry=0 }
      }
      result=digit result
    }
    if (carry) result="1" result
    print result
  }')
[ -n "$max_probe" ] || fail 'unable to calculate bounded archive size'
# head is deliberately the last pipeline process.  Its status is independent
# of gzip receiving SIGPIPE after max_probe bytes; gzip -t above already
# validated the complete compressed stream.  The resulting file is bounded to
# max_uncompressed+1 bytes before any tar operation can inspect or extract it.
set +e
gzip -cd "$archive" | head -c "$max_probe" > "$gzip_stream"
pipeline_status=$?
set -e
[ "$pipeline_status" -eq 0 ] || fail 'unable to decompress archive stream'
uncompressed_bytes=$(wc -c < "$gzip_stream" | tr -d '[:space:]')
[ "$uncompressed_bytes" -le "$max_uncompressed" ] || fail "archive exceeds uncompressed size limit: $uncompressed_bytes > $max_uncompressed"
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

required='VERSION LICENSE README.md CHANGELOG.md .env.example docker-compose.yml bin/obs scripts/install.sh scripts/uninstall.sh libexec/agentotel/dispatch.sh src/app/Dockerfile src/app/package.json src/app/package-lock.json src/backend-health/Dockerfile.collector src/backend-health/Dockerfile.victorialogs src/backend-health/Dockerfile.victoriametrics src/backend-health/Dockerfile.victoriatraces src/backend-health/health.go src/gateway/Dockerfile src/gateway/go.mod src/gateway/cmd/gateway/main.go src/mcp/go.mod src/mcp/main.go src/otel-collector/config.yaml src/grafana/Dockerfile src/dashboards/local-observability.json'
for path in $required; do
  [ -f "$extract/$root_name/$path" ] || fail "required release file is missing: $path"
  [ ! -L "$extract/$root_name/$path" ] || fail "required release file is a symlink: $path"
done

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
