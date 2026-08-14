#!/bin/sh
set -eu

root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release-test.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM

repo=$t/repo
mkdir -p "$repo"
git -C "$root" archive HEAD | tar -x -C "$repo"
mkdir -p "$repo/scripts"
cp "$root/scripts/build-release-source.sh" "$repo/scripts/"
cp "$root/scripts/verify-release-source.sh" "$repo/scripts/"
printf '2.1.0\n' > "$repo/VERSION"

git -C "$repo" init -q
git -C "$repo" config user.email release-test@example.invalid
git -C "$repo" config user.name release-test
git -C "$repo" add .
git -C "$repo" commit -qm 'release fixture'
git -C "$repo" tag -a v2.1.0 -m 'v2.1.0'

# These are ignored/generated artifacts.  They must not become source assets,
# even though they exist beside the exact tagged checkout during the build.
mkdir -p "$repo/.agentotel" "$repo/src/app/node_modules" "$repo/artifacts"
printf 'local state\n' > "$repo/.agentotel/forbidden"
printf 'fake dependency\n' > "$repo/src/app/node_modules/ignored.js"
printf 'generated report\n' > "$repo/artifacts/report.json"
test "$(git -C "$repo" check-ignore "$repo/.agentotel/forbidden")" = "$repo/.agentotel/forbidden"

out=$t/out
(cd "$repo" && scripts/build-release-source.sh v2.1.0 "$out")
archive=$out/AgentOTelStack-v2.1.0.tar.gz
checksum=$archive.sha256
test -s "$archive"
test -s "$checksum"
scripts_verify="$repo/scripts/verify-release-source.sh"
"$scripts_verify" --version 2.1.0 "$archive" "$checksum"
if tar -tzf "$archive" | grep -E '(^|/)(\.agentotel|node_modules|artifacts)(/|$)' >/dev/null; then
  echo 'ignored/generated files leaked into source archive' >&2
  exit 1
fi
if tar -tzf "$archive" | grep -E '^AgentOTelStack-v2\.1\.0/\.github(/|$)' >/dev/null; then
  echo 'CI metadata leaked into source archive despite the explicit allowlist' >&2
  exit 1
fi
if ! tar -tvzf "$archive" | grep -E 'AgentOTelStack-v2\.1\.0/CLAUDE\.md -> AGENTS\.md$' >/dev/null; then
  echo 'safe CLAUDE.md symlink was not preserved in source archive' >&2
  exit 1
fi
if RELEASE_MAX_ARCHIVE_ENTRIES=1 "$scripts_verify" "$archive" "$checksum" >/dev/null 2>&1; then
  echo 'verifier ignored archive entry count limit' >&2
  exit 1
fi
if RELEASE_MAX_ARCHIVE_BYTES=1 "$scripts_verify" "$archive" "$checksum" >/dev/null 2>&1; then
  echo 'verifier ignored archive size limit' >&2
  exit 1
fi

# A highly-compressible over-limit stream must be rejected during bounded
# preflight.  The verifier's temporary output is capped at limit+1 bytes and
# is cleaned up on rejection; it must never materialize the full bomb.
bomb_root=$t/bomb-root/AgentOTelStack-v2.1.0
mkdir -p "$bomb_root"
dd if=/dev/zero of="$bomb_root/payload" bs=1024 count=2048 >/dev/null 2>&1
mkdir -p "$t/bomb"
bomb=$t/bomb/AgentOTelStack-v2.1.0.tar.gz
tar -czf "$bomb" -C "$t/bomb-root" AgentOTelStack-v2.1.0
bomb_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$bomb" | awk '{print $1}'; else shasum -a 256 "$bomb" | awk '{print $1}'; fi)
printf '%s  %s\n' "$bomb_hash" "$(basename "$bomb")" > "$bomb.sha256"
limited_tmp=$t/limited-tmp
mkdir -p "$limited_tmp"
if TMPDIR="$limited_tmp" RELEASE_MAX_ARCHIVE_BYTES=1024 "$scripts_verify" "$bomb" "$bomb.sha256" >"$t/bomb.out" 2>&1; then
  echo 'verifier accepted an over-limit compressed archive' >&2
  exit 1
fi
grep -F 'archive exceeds uncompressed size limit' "$t/bomb.out" >/dev/null
if find "$limited_tmp" -type f -print -quit | grep -q .; then
  echo 'bounded preflight temporary output was not cleaned up' >&2
  exit 1
fi

# Rebuilding the same tag after ignored files change must be byte-for-byte
# reproducible.
printf 'another local state\n' > "$repo/.agentotel/forbidden"
printf 'another report\n' > "$repo/artifacts/report.json"
out2=$t/out2
(cd "$repo" && scripts/build-release-source.sh v2.1.0 "$out2")
cmp "$archive" "$out2/AgentOTelStack-v2.1.0.tar.gz"
cmp "$checksum" "$out2/AgentOTelStack-v2.1.0.tar.gz.sha256"

# A checkout that has moved past the tag is rejected, even when the tag still
# exists.  This guards the exact-commit contract.
printf 'post-tag change\n' > "$repo/post-tag.txt"
git -C "$repo" add post-tag.txt
git -C "$repo" commit -qm 'post-tag change'
if (cd "$repo" && scripts/build-release-source.sh v2.1.0 "$t/mismatch") >/dev/null 2>&1; then
  echo 'build unexpectedly accepted a checkout not at the tag commit' >&2
  exit 1
fi

# A generated project-local file must not become publishable merely because it
# was force-added to the index.
printf '2.1.1\n' > "$repo/VERSION"
git -C "$repo" add VERSION
git -C "$repo" add -f .agentotel/forbidden
git -C "$repo" commit -qm 'tracked generated output fixture'
git -C "$repo" tag -a v2.1.1 -m 'v2.1.1'
if (cd "$repo" && scripts/build-release-source.sh v2.1.1 "$t/forbidden") >/dev/null 2>&1; then
  echo 'build unexpectedly accepted a tracked .agentotel output' >&2
  exit 1
fi

# Each secret-like path is force-added to an otherwise clean tagged checkout;
# the builder must reject it before asking git archive for any paths.
secret_case(){
  name=$1
  path=$2
  secret_repo=$t/secret-$name
  secret_out=$t/secret-out-$name
  git clone -q "$repo" "$secret_repo"
  git -C "$secret_repo" checkout -q v2.1.0
  mkdir -p "$secret_repo/$(dirname "$path")"
  printf 'must never ship\n' > "$secret_repo/$path"
  printf '2.2.1\n' > "$secret_repo/VERSION"
  git -C "$secret_repo" add VERSION
  git -C "$secret_repo" add -f "$path"
  git -C "$secret_repo" commit -qm "secret fixture $name"
  git -C "$secret_repo" tag -a v2.2.1 -m v2.2.1
  if (cd "$secret_repo" && scripts/build-release-source.sh v2.2.1 "$secret_out") >"$t/secret-$name.out" 2>&1; then
    echo "build unexpectedly accepted tracked secret fixture: $path" >&2
    exit 1
  fi
  grep -F "tracked secret-like path is forbidden: $path" "$t/secret-$name.out" >/dev/null
}
secret_case dotenv .env
secret_case pem cert.pem
secret_case key private.key
secret_case credentials credentials/token

# Validate the actual install entry point from the extracted source asset.
extract=$t/extracted
mkdir -p "$extract"
tar -xzf "$archive" -C "$extract"
export HOME="$t/home"
export XDG_DATA_HOME="$t/data"
export XDG_BIN_HOME="$t/bin"
export XDG_CONFIG_HOME="$t/config"
mkdir -p "$HOME"
"$extract/AgentOTelStack-v2.1.0/scripts/install.sh" --without-mcp 2.1.0 >/dev/null
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 2.1.0
test -s "$XDG_DATA_HOME/agentotel/current/manifest.sha256"

echo 'release source archive checks passed'
