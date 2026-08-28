#!/bin/sh
set -eu
umask 077
# Publish mode packages only a clean exact-tag checkout.  Local development may
# explicitly opt into the current-tree snapshot contract with
# RELEASE_SOURCE_MODE=dirty; that mode still requires HEAD to be the requested
# tag and applies the same canonical path policy.  Never infer dirty mode from
# the caller or from CI state.
root=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

usage(){
  echo "usage: $0 [vX.Y.Z] [output-directory]" >&2
  exit 2
}
fail(){ echo "release source: $*" >&2; exit 1; }

tag=${1:-${RELEASE_TAG:-${GITHUB_REF_NAME:-}}}
out=${2:-${RELEASE_OUTPUT_DIR:-$root/dist}}
[ -n "$tag" ] || usage
[ "$tag" != --help ] || usage
case "$tag" in refs/tags/*) tag=${tag#refs/tags/};; esac
case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "invalid release tag: $tag (expected vX.Y.Z)";;
esac
version=${tag#v}
case "$version" in
  ''|*[!0-9.]*|*.*.*.*|.*|*.|*..*) fail "invalid release version: $version";;
esac
major=${version%%.*}; version_tail=${version#*.}; minor=${version_tail%%.*}; patch_version=${version_tail#*.}
case "$major:$minor:$patch_version" in
  0[0-9]*:*|*:0[0-9]*:*|*:*:0[0-9]*) fail "invalid release version: $version";;
esac
source_mode=${RELEASE_SOURCE_MODE:-publish}
case "$source_mode" in
  publish|dirty) :;;
  *) fail "invalid RELEASE_SOURCE_MODE: $source_mode (expected publish or dirty)";;
esac

git show-ref --verify --quiet "refs/tags/$tag" || fail "tag does not exist: $tag"
commit=$(git rev-parse --verify "$tag^{commit}" 2>/dev/null) || fail "tag does not resolve to a commit: $tag"
head=$(git rev-parse --verify HEAD 2>/dev/null) || fail 'unable to resolve checkout HEAD'
[ "$commit" = "$head" ] || fail "checkout HEAD $head does not match tag $tag commit $commit"
version_at_tag=$(git show "$commit:VERSION" 2>/dev/null) || fail 'tagged commit has no VERSION file'
[ "$version_at_tag" = "$version" ] || fail "tagged VERSION is $version_at_tag, expected $version"
if [ "$source_mode" = publish ]; then
  status=$(git status --porcelain=v1 --untracked-files=all --ignored) || fail 'unable to inspect checkout cleanliness'
  [ -z "$status" ] || fail "publish mode requires a clean exact-tag tree (use RELEASE_SOURCE_MODE=dirty only for local snapshot tests): $(printf '%s\\n' "$status" | paste -sd ';' -)"
fi

entries=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-entries.XXXXXX")
staging=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release.XXXXXX")
backup_archive=''
backup_checksum=''
cleanup(){
  rm -f "$entries"
  rm -rf "$staging"
  [ -z "${backup_archive:-}" ] || rm -f "$backup_archive"
  [ -z "${backup_checksum:-}" ] || rm -f "$backup_checksum"
}
trap cleanup EXIT HUP INT TERM

# Keep this list explicit. `.github` is intentionally not a release asset; all
# source/runtime inputs needed by the installer and verification gates are here.
allowlist='.env.example
.gitignore
.gitleaks.toml
AGENTS.md
CLAUDE.md
CHANGELOG.md
LICENSE
Makefile
README.md
VERSION
docker-compose.yml
bin
libexec
obs
workload
scripts
tests
docs
e2e
src'
required='VERSION LICENSE README.md CHANGELOG.md docs/README.md docs/ko/README.md docs/AGENT_SETUP.md docs/ARCHITECTURE.md docs/CONNECT.md docs/DASHBOARD.md docs/DEVELOPMENT.md docs/JSON_CONTRACT.md docs/OPERATIONS.md docs/QUERY.md docs/RELEASING.md docs/REPLACE_SAMPLE_APP.md docs/SAMPLING_AND_COMPLETENESS.md docs/SECURITY.md docs/TROUBLESHOOTING.md docs/ko/AGENT_SETUP.md docs/ko/ARCHITECTURE.md docs/ko/CONNECT.md docs/ko/DASHBOARD.md docs/ko/DEVELOPMENT.md docs/ko/JSON_CONTRACT.md docs/ko/OPERATIONS.md docs/ko/QUERY.md docs/ko/RELEASING.md docs/ko/REPLACE_SAMPLE_APP.md docs/ko/SAMPLING_AND_COMPLETENESS.md docs/ko/SECURITY.md docs/ko/TROUBLESHOOTING.md VERSION LICENSE README.md CHANGELOG.md .env.example docker-compose.yml bin/obs scripts/install.sh scripts/uninstall.sh scripts/release_source_policy.py libexec/agentotel/dispatch.sh src/app/Dockerfile src/app/package.json src/app/package-lock.json src/backend-health/Dockerfile.collector src/dashboard/Dockerfile src/dashboard/LICENSE src/dashboard/go.mod src/dashboard/README.md src/dashboard/cmd/dashboard/main.go src/dashboard/cmd/dashboard/main_test.go src/dashboard/internal/proxy/proxy.go src/dashboard/internal/proxy/proxy_test.go src/dashboard/internal/ui/ui.go src/dashboard/internal/ui/ui_test.go src/dashboard/internal/ui/app_state_test.js src/dashboard/internal/ui/static/index.html src/dashboard/internal/ui/static/assets/app.js src/dashboard/internal/ui/static/assets/request-state.js src/dashboard/internal/ui/static/assets/styles.css src/backend-health/Dockerfile.victorialogs src/backend-health/Dockerfile.victoriametrics src/backend-health/Dockerfile.victoriatraces src/backend-health/health.go src/gateway/Dockerfile src/gateway/go.mod src/gateway/cmd/gateway/main.go src/gateway/internal/query/query.go src/gateway/internal/query/client.go src/gateway/internal/query/correlation/correlation.go src/gateway/internal/status/status.go src/gateway/schemas/context.schema.json src/gateway/schemas/correlate-v1.json src/gateway/schemas/correlate.schema.json src/gateway/schemas/envelope.schema.json src/gateway/schemas/errors.schema.json src/gateway/schemas/services.schema.json src/mcp/go.mod src/mcp/main.go src/otel-collector/config.yaml'

# Existing tracked retired, secret-like, or generated paths are rejected even
# when a dirty working tree has deleted them. Keep this check on the tagged
# tree so a legacy tag cannot be repackaged by a current checkout policy.
git ls-tree -r --name-only "$commit" >"$entries" || fail 'unable to inspect tagged tree'
python3 - "$root" "$entries" <<'PY' || exit 1
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / "scripts"))
import release_source_policy as policy

for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    diagnostic = policy.diagnostic(line, tracked=True)
    if diagnostic:
        raise SystemExit(diagnostic)
PY

for path in $required; do
  [ -e "$root/$path" ] || [ -L "$root/$path" ] || fail "required release file is missing from working tree: $path"
done
[ -f "$root/src/dashboard/LICENSE" ] || fail 'src/dashboard/LICENSE is required'
cmp -s "$root/LICENSE" "$root/src/dashboard/LICENSE" || fail 'src/dashboard/LICENSE must exactly match the root LICENSE'

archive_name="AgentOTelStack-v${version}.tar.gz"
checksum_name="${archive_name}.sha256"
python3 - "$root" "$out" "$allowlist" <<'PY' || fail 'output directory is inside an allowlisted source root'
import pathlib
import sys

source_root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
for item in sys.argv[3].splitlines():
    candidate = (source_root / item).resolve()
    try:
        output.relative_to(candidate)
    except ValueError:
        continue
    raise SystemExit(f"output {output} is inside allowlisted root {candidate}")
PY
mkdir -p "$out"
[ -d "$out" ] || fail "output path is not a directory: $out"
archive_tmp="$staging/$archive_name"
checksum_tmp="$staging/$checksum_name"

# Python's standard library is already an existing project/CI dependency (the
# local and hosted gates parse JSON with python3). It gives macOS and Linux the
# same deterministic tar headers, sorted current-tree walk, symlink handling,
# and gzip mtime normalization without adding a third-party release dependency.
python3 - "$root" "$archive_tmp" "$version" "$allowlist" <<'PY' || exit 1
import gzip
import os
import pathlib
import posixpath
import stat
import subprocess
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2])
version = sys.argv[3]
allowlist = sys.argv[4].splitlines()
prefix = f"AgentOTelStack-v{version}"
sys.path.insert(0, str(root / "scripts"))
import release_source_policy as policy


def tracked(path: str) -> bool:
    # Use the index only to distinguish a force-tracked generated path from an
    # ignored/untracked cache that should be skipped in the explicit dirty mode.
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0

def validate_symlink(path: str, rel: str):
    target = os.readlink(path)
    if not target or target.startswith("/") or "\\" in target or ":" in target:
        raise SystemExit(f"unsafe current-tree symlink: {rel} -> {target}")
    pieces = target.split("/")
    if any(piece in {"", ".", ".."} for piece in pieces):
        raise SystemExit(f"unsafe current-tree symlink: {rel} -> {target}")
    parent = posixpath.dirname(rel)
    resolved = posixpath.normpath(posixpath.join(parent, target))
    if resolved not in discovered:
        raise SystemExit(f"current-tree symlink target is outside release snapshot: {rel} -> {target}")

# Walk every allowlisted current-tree path. Ignored generated directories are
# skipped only when untracked; a force-tracked generated output is rejected.
discovered = {prefix}
def visit(path: pathlib.Path, rel: str):
    kind = policy.classify(rel)
    if kind == "retired":
        raise SystemExit(f"retired dashboard path is forbidden: {rel}")
    if kind == "secret":
        raise SystemExit(f"secret-like path is forbidden: {rel}")
    if kind == "dashboard-artifact":
        raise SystemExit(f"dashboard build artifact is forbidden: {rel}")
    if kind == "generated":
        if tracked(rel):
            raise SystemExit(f"tracked generated output is forbidden: {rel}")
        return
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        raise SystemExit(f"allowlisted working-tree path is missing: {rel}")
    discovered.add(rel)
    if stat.S_ISLNK(mode):
        return
    if stat.S_ISDIR(mode):
        children = sorted(path.iterdir(), key=lambda item: item.name)
        for child in children:
            child_rel = f"{rel}/{child.name}" if rel else child.name
            visit(child, child_rel)
    elif not stat.S_ISREG(mode):
        raise SystemExit(f"unsupported working-tree entry: {rel}")

for item in allowlist:
    path = root / item
    visit(path, item)

# Symlink validation occurs after the full walk so forward references such as
# CLAUDE.md -> AGENTS.md are accepted while escaping links are not.
for rel in sorted(discovered):
    if rel == prefix:
        continue
    path = root / rel
    if path.is_symlink():
        validate_symlink(path, rel)

# Add parent directories that were not explicit allowlist roots, then emit
# deterministic tar headers and gzip bytes.
all_paths = set(discovered)
for rel in list(discovered):
    parent = posixpath.dirname(rel)
    while parent and parent != prefix:
        all_paths.add(parent)
        parent = posixpath.dirname(parent)
all_paths.add(prefix)

def tar_name(rel):
    return f"{prefix}/{rel}" if rel != prefix else prefix

def info(rel, path):
    st = path.lstat()
    mode = st.st_mode
    ti = tarfile.TarInfo(tar_name(rel))
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = 0
    if stat.S_ISDIR(mode):
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.size = 0
    elif stat.S_ISLNK(mode):
        ti.type = tarfile.SYMTYPE
        ti.mode = 0o777
        ti.linkname = os.readlink(path)
        ti.size = 0
    elif stat.S_ISREG(mode):
        ti.type = tarfile.REGTYPE
        ti.mode = 0o755 if mode & stat.S_IXUSR else 0o644
        ti.size = st.st_size
    else:
        raise SystemExit(f"unsupported working-tree entry: {rel}")
    return ti

out.parent.mkdir(parents=True, exist_ok=True)
with out.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as gz, tarfile.open(fileobj=gz, mode="w") as archive:
    for rel in sorted(all_paths):
        if rel == prefix:
            archive.addfile(info(rel, root))
            continue
        path = root / rel
        # Parent directories synthesized above are always real directories.
        if not path.exists() and not path.is_symlink():
            raise SystemExit(f"snapshot path disappeared during archive: {rel}")
        ti = info(rel, path)
        if ti.isreg():
            with path.open("rb") as handle:
                archive.addfile(ti, handle)
        else:
            archive.addfile(ti)
PY

hash_file(){
  file=$1
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
hash=$(hash_file "$archive_tmp") || fail 'unable to calculate source archive checksum'
printf '%s  %s\n' "$hash" "$archive_name" >"$checksum_tmp"

# Verify before replacing either final output. The verifier performs the bounded
# decompression, tar metadata quota, root, path, symlink, and dashboard checks.
"$root/scripts/verify-release-source.sh" --version "$version" "$archive_tmp" "$checksum_tmp" || fail 'generated archive did not pass verification'

archive_final="$out/$archive_name"
checksum_final="$out/$checksum_name"
backup_archive="$out/.${archive_name}.previous.$$"
backup_checksum="$out/.${checksum_name}.previous.$$"
archive_saved=false
checksum_saved=false
archive_published=false
checksum_published=false
rollback_pair(){
  rollback_failed=0
  if [ "$archive_saved" = true ] || [ "$archive_published" = true ]; then
    rm -f "$archive_final" || rollback_failed=1
  fi
  if [ "$checksum_saved" = true ] || [ "$checksum_published" = true ]; then
    rm -f "$checksum_final" || rollback_failed=1
  fi
  if [ "$archive_saved" = true ]; then
    mv -f "$backup_archive" "$archive_final" || rollback_failed=1
  fi
  if [ "$checksum_saved" = true ]; then
    mv -f "$backup_checksum" "$checksum_final" || rollback_failed=1
  fi
  return "$rollback_failed"
}
publish_pair(){
  [ ! -L "$archive_final" ] || { echo "release source: output archive is a symlink: $archive_final" >&2; return 1; }
  [ ! -L "$checksum_final" ] || { echo "release source: output checksum is a symlink: $checksum_final" >&2; return 1; }
  [ ! -e "$archive_final" ] || [ -f "$archive_final" ] || { echo "release source: output archive is not a regular file: $archive_final" >&2; return 1; }
  [ ! -e "$checksum_final" ] || [ -f "$checksum_final" ] || { echo "release source: output checksum is not a regular file: $checksum_final" >&2; return 1; }
  if [ -e "$archive_final" ]; then
    mv -f "$archive_final" "$backup_archive" || return 1
    archive_saved=true
  fi
  if [ -e "$checksum_final" ]; then
    if ! mv -f "$checksum_final" "$backup_checksum"; then
      rollback_pair || echo 'release source: rollback failed after checksum backup failure' >&2
      return 1
    fi
    checksum_saved=true
  fi
  if ! mv -f "$archive_tmp" "$archive_final"; then
    rollback_pair || echo 'release source: rollback failed after archive publication failure' >&2
    return 1
  fi
  archive_published=true
  if ! mv -f "$checksum_tmp" "$checksum_final"; then
    rollback_pair || echo 'release source: rollback failed after checksum publication failure' >&2
    return 1
  fi
  checksum_published=true
  rm -f "$backup_archive" "$backup_checksum"
  archive_saved=false
  checksum_saved=false
  archive_published=false
  checksum_published=false
  return 0
}
publish_pair || fail 'unable to publish archive/checksum pair; previous pair was restored when possible'
echo "built $archive_final"
echo "built $checksum_final"
