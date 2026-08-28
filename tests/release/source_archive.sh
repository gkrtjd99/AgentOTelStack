#!/bin/sh
set -eu

root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release-test.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM

repo=$t/repo
mkdir -p "$repo"
# Build the synthetic tagged checkout from the complete CURRENT allowlisted
# working-tree snapshot. A stale `git archive HEAD` plus a partial overlay would
# omit current docs, Make/E2E/config inputs, and newly split dashboard assets.
python3 - "$root" "$repo" <<'PY'
import os
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
allowlist = '.env.example .gitignore .gitleaks.toml AGENTS.md CLAUDE.md CHANGELOG.md LICENSE Makefile README.md VERSION docker-compose.yml bin libexec obs workload scripts tests docs e2e src'.split()
skip_dirs = {'.git', '.agentotel', 'node_modules', '.cache', '.trivy-cache', '.npm', '.yarn', '.pnpm-store', '.nyc_output', '__pycache__', 'artifacts', 'coverage', 'test-results', 'playwright-report', 'playwright-artifacts', 'build', 'dist', 'tmp'}

def ignore(directory, names):
    return {name for name in names if name in skip_dirs}

for item in allowlist:
    src = source / item
    if not src.exists() and not src.is_symlink():
        raise SystemExit(f'missing current allowlisted input: {item}')
    dst = destination / item
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, dst, symlinks=True, ignore=ignore)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst, follow_symlinks=False)
# The checkout under test is a clean source checkout, not the operator's local
# ignored MCP build output.
(destination / 'src/mcp/mcp').unlink(missing_ok=True)
PY

git -C "$repo" init -q
# Keep the synthetic repository self-contained: hosted runners may not have a
# global Git identity, and this fixture must never modify the operator's one.
git -C "$repo" config --local user.email release-test@example.invalid
git -C "$repo" config --local user.name release-test
git -C "$repo" add .
git -C "$repo" commit -qm 'release fixture'
git -C "$repo" tag -a v2.1.0 -m 'v2.1.0'

# A clean exact-tag checkout is the only publish-mode input.
clean_out=$t/clean-out
(cd "$repo" && scripts/build-release-source.sh v2.1.0 "$clean_out")
test -s "$clean_out/AgentOTelStack-v2.1.0.tar.gz"

# These are ignored/generated artifacts. They must not become source assets,
# even though they exist beside the exact tagged checkout during an explicit
# local dirty snapshot build.
mkdir -p "$repo/.agentotel" "$repo/src/app/node_modules" "$repo/artifacts" \
  "$repo/src/app/__pycache__" "$repo/src/app/.npm" "$repo/src/app/.yarn" \
  "$repo/src/app/.pnpm-store" "$repo/src/app/.nyc_output" \
  "$repo/src/app/test-results" "$repo/src/app/playwright-report" \
  "$repo/src/app/playwright-artifacts"
printf 'local state\n' > "$repo/.agentotel/forbidden"
printf 'fake dependency\n' > "$repo/src/app/node_modules/ignored.js"
printf 'generated report\n' > "$repo/artifacts/report.json"
printf 'macOS clutter\n' > "$repo/src/app/.DS_Store"
printf 'cache\n' > "$repo/src/app/__pycache__/module.pyc"
printf 'cache\n' > "$repo/src/app/.npm/cache.tmp"
printf 'cache\n' > "$repo/src/app/.yarn/cache.tmp"
printf 'cache\n' > "$repo/src/app/.pnpm-store/cache.tmp"
printf 'coverage\n' > "$repo/src/app/.nyc_output/coverage.json"
printf 'results\n' > "$repo/src/app/test-results/result.tmp"
printf 'report\n' > "$repo/src/app/playwright-report/index.html"
printf 'artifact\n' > "$repo/src/app/playwright-artifacts/run.tmp"
printf 'temporary\n' > "$repo/docs/local.tmp"
printf 'profile\n' > "$repo/src/gateway/example.coverprofile"
printf 'installer\n' > "$repo/src/app/current.tmp.123"
printf 'installer\n' > "$repo/src/app/previous.tmp.123"
printf 'installer\n' > "$repo/src/app/manifest.sha256.tmp.123"
printf 'installer\n' > "$repo/src/app/foo.install.tmp.123"
printf 'style\n' > "$repo/src/app/.eslintcache"
printf 'style\n' > "$repo/src/app/.stylelintcache"
test "$(git -C "$repo" check-ignore "$repo/.agentotel/forbidden")" = "$repo/.agentotel/forbidden"

if (cd "$repo" && scripts/build-release-source.sh v2.1.0 "$t/publish-dirty") >"$t/publish-dirty.out" 2>&1; then
  echo 'publish mode accepted a dirty/ignored checkout' >&2
  exit 1
fi
grep -F 'publish mode requires a clean exact-tag tree' "$t/publish-dirty.out" >/dev/null

out=$t/out
(cd "$repo" && RELEASE_SOURCE_MODE=dirty scripts/build-release-source.sh v2.1.0 "$out")
archive=$out/AgentOTelStack-v2.1.0.tar.gz
checksum=$archive.sha256
test -s "$archive"
test -s "$checksum"
scripts_verify="$repo/scripts/verify-release-source.sh"
"$scripts_verify" --version 2.1.0 "$archive" "$checksum"
if tar -tzf "$archive" | grep -E '(^|/)(\.agentotel|node_modules|artifacts|__pycache__|\.npm|\.yarn|\.pnpm-store|\.nyc_output|test-results|playwright-report|playwright-artifacts)(/|$)|(^|/)(\.DS_Store|\.eslintcache|\.stylelintcache|[^/]+\.tmp|[^/]+\.coverprofile|current\.tmp\.|previous\.tmp\.|manifest\.sha256\.tmp\.|[^/]+\.install\.tmp\.)(/|$)' >/dev/null; then
  echo 'ignored/generated files leaked into source archive' >&2
  exit 1
fi
if tar -tzf "$archive" | grep -E '^AgentOTelStack-v2\.1\.0/\.github(/|$)' >/dev/null; then
  echo 'CI metadata leaked into source archive despite the explicit allowlist' >&2
  exit 1
fi
if tar -tzf "$archive" | grep -E '(^|/)(src/(grafana|dashboards)|tests/dashboard_log_query\.sh|scripts/verify-trivy-waivers\.sh|security/(grafana-trivy-waivers|test-trivy-waivers))' >/dev/null; then
  echo 'retired dashboard source leaked into source archive' >&2
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

# A checksum mismatch is a distinct failure from a structurally invalid archive
# carrying a freshly recomputed checksum.
wrong_checksum="$t/wrong-checksum.sha256"
printf '%064d  %s\n' 0 "$(basename "$archive")" >"$wrong_checksum"
if "$scripts_verify" "$archive" "$wrong_checksum" >"$t/wrong-checksum.out" 2>&1; then
  echo 'verifier accepted a checksum mismatch' >&2
  exit 1
fi
grep -F 'checksum mismatch' "$t/wrong-checksum.out" >/dev/null

# The verifier must reject an archive that omits a required dashboard asset even
# when an attacker recomputes the companion checksum.
missing_root=$t/missing-root
mkdir -p "$missing_root"
tar -xzf "$archive" -C "$missing_root"
rm -f "$missing_root/AgentOTelStack-v2.1.0/src/dashboard/internal/ui/static/assets/styles.css"
missing=$t/missing/AgentOTelStack-v2.1.0.tar.gz
mkdir -p "$(dirname "$missing")"
COPYFILE_DISABLE=1 tar -czf "$missing" -C "$missing_root" AgentOTelStack-v2.1.0
missing_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$missing" | awk '{print $1}'; else shasum -a 256 "$missing" | awk '{print $1}'; fi)
printf '%s  %s\n' "$missing_hash" "$(basename "$missing")" > "$missing.sha256"
if "$scripts_verify" "$missing" "$missing.sha256" >"$t/missing.out" 2>&1; then
  echo 'verifier accepted an archive missing a dashboard asset' >&2
  exit 1
fi
grep -F 'required release file is missing: src/dashboard/internal/ui/static/assets/styles.css' "$t/missing.out" >/dev/null

missing_gateway_root=$t/missing-gateway-root
mkdir -p "$missing_gateway_root"
tar -xzf "$archive" -C "$missing_gateway_root"
rm -f "$missing_gateway_root/AgentOTelStack-v2.1.0/src/gateway/internal/query/query.go"
missing_gateway=$t/missing-gateway/AgentOTelStack-v2.1.0.tar.gz
mkdir -p "$(dirname "$missing_gateway")"
COPYFILE_DISABLE=1 tar -czf "$missing_gateway" -C "$missing_gateway_root" AgentOTelStack-v2.1.0
missing_gateway_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$missing_gateway" | awk '{print $1}'; else shasum -a 256 "$missing_gateway" | awk '{print $1}'; fi)
printf '%s  %s\n' "$missing_gateway_hash" "$(basename "$missing_gateway")" >"$missing_gateway.sha256"
if "$scripts_verify" "$missing_gateway" "$missing_gateway.sha256" >"$t/missing-gateway.out" 2>&1; then
  echo 'verifier accepted an archive missing Gateway query internals' >&2
  exit 1
fi
grep -F 'required release file is missing: src/gateway/internal/query/query.go' "$t/missing-gateway.out" >/dev/null

artifact_archive_root=$t/artifact-archive-root
mkdir -p "$artifact_archive_root"
tar -xzf "$archive" -C "$artifact_archive_root"
mkdir -p "$artifact_archive_root/AgentOTelStack-v2.1.0/src/dashboard/dashboard"
printf 'forced binary\n' >"$artifact_archive_root/AgentOTelStack-v2.1.0/src/dashboard/dashboard/dashboard"
artifact_archive=$t/artifact-archive/AgentOTelStack-v2.1.0.tar.gz
mkdir -p "$(dirname "$artifact_archive")"
COPYFILE_DISABLE=1 tar -czf "$artifact_archive" -C "$artifact_archive_root" AgentOTelStack-v2.1.0
artifact_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$artifact_archive" | awk '{print $1}'; else shasum -a 256 "$artifact_archive" | awk '{print $1}'; fi)
printf '%s  %s\n' "$artifact_hash" "$(basename "$artifact_archive")" >"$artifact_archive.sha256"
if "$scripts_verify" "$artifact_archive" "$artifact_archive.sha256" >"$t/artifact-archive.out" 2>&1; then
  echo 'verifier accepted a dashboard build artifact' >&2
  exit 1
fi
grep -F 'dashboard build artifact is forbidden' "$t/artifact-archive.out" >/dev/null || {
  cat "$t/artifact-archive.out" >&2
  exit 1
}

# Parentless generated artifact fixture: tar intentionally omits every parent
# directory header and emits only the file path. The verifier must classify the
# descendant by its logical path, not rely on a parent directory entry.
parentless="$t/parentless/AgentOTelStack-v2.1.0.tar.gz"
mkdir -p "$(dirname "$parentless")"
python3 - "$archive" "$parentless" <<'PY'
import gzip
import pathlib
import sys
import tarfile
import io

source = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
with tarfile.open(source, 'r:gz') as source_tar:
    with out.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as destination:
            for member in source_tar:
                payload = source_tar.extractfile(member) if member.isreg() else None
                destination.addfile(member, payload)
            artifact = tarfile.TarInfo('AgentOTelStack-v2.1.0/src/dashboard/dashboard/dashboard')
            artifact.mode = 0o755
            artifact.size = len(b'parentless artifact\n')
            destination.addfile(artifact, io.BytesIO(b'parentless artifact\n'))
PY
parentless_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$parentless" | awk '{print $1}'; else shasum -a 256 "$parentless" | awk '{print $1}'; fi)
printf '%s  %s\n' "$parentless_hash" "$(basename "$parentless")" >"$parentless.sha256"
if "$scripts_verify" "$parentless" "$parentless.sha256" >"$t/parentless.out" 2>&1; then
  echo 'verifier accepted a parentless dashboard build artifact' >&2
  exit 1
fi
grep -F 'dashboard build artifact is forbidden: src/dashboard/dashboard/dashboard' "$t/parentless.out" >/dev/null

# A checksum-preserving source mutation must fail before extraction.
tamper_root=$t/tamper-root
mkdir -p "$tamper_root"
tar -xzf "$archive" -C "$tamper_root"
printf 'tampered dashboard asset\n' > "$tamper_root/AgentOTelStack-v2.1.0/src/dashboard/internal/ui/static/assets/app.js"
tamper=$t/tamper/AgentOTelStack-v2.1.0.tar.gz
mkdir -p "$(dirname "$tamper")"
COPYFILE_DISABLE=1 tar -czf "$tamper" -C "$tamper_root" AgentOTelStack-v2.1.0
if "$scripts_verify" "$tamper" "$checksum" >/dev/null 2>&1; then
  echo 'verifier accepted a tampered dashboard asset' >&2
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
COPYFILE_DISABLE=1 tar -czf "$bomb" -C "$t/bomb-root" AgentOTelStack-v2.1.0
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
if RELEASE_MAX_ENTRY_BYTES=1 "$scripts_verify" "$archive" "$checksum" >"$t/entry-limit.out" 2>&1; then
  echo 'verifier ignored per-entry logical size limit' >&2
  exit 1
fi
if RELEASE_MAX_LOGICAL_BYTES=1 "$scripts_verify" "$archive" "$checksum" >"$t/logical-limit.out" 2>&1; then
  echo 'verifier ignored cumulative logical size limit' >&2
  exit 1
fi

# PAX/GNU sparse metadata is rejected before extraction, even when the physical
# tar stream is tiny.
sparse="$t/sparse.tar.gz"
python3 - "$sparse" <<'PY'
import gzip
import pathlib
import sys
import tarfile

out = pathlib.Path(sys.argv[1])
with out.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
    with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as archive:
        root = tarfile.TarInfo('AgentOTelStack-v2.1.0')
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        archive.addfile(root)
        member = tarfile.TarInfo('AgentOTelStack-v2.1.0/sparse.bin')
        member.size = 1
        member.pax_headers = {'GNU.sparse.map': '0,1'}
        archive.addfile(member, __import__('io').BytesIO(b'x'))
PY
sparse_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$sparse" | awk '{print $1}'; else shasum -a 256 "$sparse" | awk '{print $1}'; fi)
printf '%s  %s\n' "$sparse_hash" "$(basename "$sparse")" >"$sparse.sha256"
if "$scripts_verify" "$sparse" "$sparse.sha256" >"$t/sparse.out" 2>&1; then
  echo 'verifier accepted sparse tar metadata' >&2
  exit 1
fi
grep -F 'sparse' "$t/sparse.out" >/dev/null

# Rebuilding the same tag after ignored files change must be byte-for-byte
# reproducible.
printf 'another local state\n' > "$repo/.agentotel/forbidden"
printf 'another report\n' > "$repo/artifacts/report.json"
out2=$t/out2
(cd "$repo" && RELEASE_SOURCE_MODE=dirty scripts/build-release-source.sh v2.1.0 "$out2")
cmp "$archive" "$out2/AgentOTelStack-v2.1.0.tar.gz"
cmp "$checksum" "$out2/AgentOTelStack-v2.1.0.tar.gz.sha256"

# Dirty development mode intentionally includes tracked edits and ordinary
# untracked files under allowlisted roots; it never falls back silently from
# publish mode.
dirty_repo=$t/dirty-repo
git clone -q "$repo" "$dirty_repo"
git -C "$dirty_repo" checkout -q v2.1.0
printf 'local tracked development note\n' >>"$dirty_repo/README.md"
printf 'ordinary untracked development note\n' >"$dirty_repo/docs/local-dev.txt"
if (cd "$dirty_repo" && scripts/build-release-source.sh v2.1.0 "$t/dirty-publish") >"$t/dirty-publish.out" 2>&1; then
  echo 'publish mode accepted tracked and ordinary untracked changes' >&2
  exit 1
fi
grep -F 'publish mode requires a clean exact-tag tree' "$t/dirty-publish.out" >/dev/null
(cd "$dirty_repo" && RELEASE_SOURCE_MODE=dirty scripts/build-release-source.sh v2.1.0 "$t/dirty-dev")
tar -xOf "$t/dirty-dev/AgentOTelStack-v2.1.0.tar.gz" AgentOTelStack-v2.1.0/docs/local-dev.txt | grep -F 'ordinary untracked development note' >/dev/null
tar -xOf "$t/dirty-dev/AgentOTelStack-v2.1.0.tar.gz" AgentOTelStack-v2.1.0/README.md | grep -F 'local tracked development note' >/dev/null

# Output roots are excluded before creation, and two builds never ingest the
# prior archive/checksum even when the destination is reused.
if (cd "$repo" && RELEASE_SOURCE_MODE=dirty scripts/build-release-source.sh v2.1.0 "$repo/src/release-output") >"$t/output-recursion.out" 2>&1; then
  echo 'builder accepted output directory inside an allowlisted source root' >&2
  exit 1
fi
grep -F 'output directory is inside an allowlisted source root' "$t/output-recursion.out" >/dev/null
test ! -e "$repo/src/release-output"

# A normal second-publication failure restores the previous archive/checksum
# pair. The fake mv fails once only for the checksum final destination, allowing
# the rollback move to complete.
pair_repo=$t/pair-repo
git clone -q "$repo" "$pair_repo"
git -C "$pair_repo" checkout -q v2.1.0
pair_out=$t/pair-out
(cd "$pair_repo" && scripts/build-release-source.sh v2.1.0 "$pair_out")
cp "$pair_out/AgentOTelStack-v2.1.0.tar.gz" "$t/old-archive"
cp "$pair_out/AgentOTelStack-v2.1.0.tar.gz.sha256" "$t/old-checksum"
mkdir -p "$t/fake-mv"
real_mv=$(command -v mv)
# The wrapper state is persisted because each exec gets a fresh environment.
cat >"$t/fake-mv/mv" <<EOF
#!/bin/sh
last=''
for arg do last=\$arg; done
if [ "\${PAIR_FAIL_ONCE:-}" = 1 ] && [ ! -e "$t/pair-failed" ] && [ "\$last" = "$pair_out/AgentOTelStack-v2.1.0.tar.gz.sha256" ]; then
  : >"$t/pair-failed"
  printf 'forced second publication move failure\n' >&2
  exit 73
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$t/fake-mv/mv"
if (cd "$pair_repo" && PATH="$t/fake-mv:$PATH" PAIR_FAIL_ONCE=1 scripts/build-release-source.sh v2.1.0 "$pair_out") >"$t/pair-failure.out" 2>&1; then
  echo 'builder accepted forced second publication failure' >&2
  exit 1
fi
cmp "$t/old-archive" "$pair_out/AgentOTelStack-v2.1.0.tar.gz"
cmp "$t/old-checksum" "$pair_out/AgentOTelStack-v2.1.0.tar.gz.sha256"
if find "$pair_out" -maxdepth 1 -name '*.previous.*' -o -name '*.tmp.*' | grep -q .; then
  echo 'pair publication left backup or temporary output' >&2
  exit 1
fi

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

# A force-tracked dashboard build artifact is rejected just as firmly as an
# ignored local artifact; source splitting must never publish this binary path.
artifact_repo=$t/artifact-repo
artifact_out=$t/artifact-out
git clone -q "$repo" "$artifact_repo"
git -C "$artifact_repo" config --local user.email release-test@example.invalid
git -C "$artifact_repo" config --local user.name release-test
git -C "$artifact_repo" checkout -q v2.1.0
mkdir -p "$artifact_repo/src/dashboard/dashboard"
printf 'forced binary\n' > "$artifact_repo/src/dashboard/dashboard/dashboard"
printf '2.1.2\n' > "$artifact_repo/VERSION"
git -C "$artifact_repo" add VERSION
git -C "$artifact_repo" add -f src/dashboard/dashboard/dashboard
git -C "$artifact_repo" commit -qm 'tracked dashboard build artifact fixture'
git -C "$artifact_repo" tag -a v2.1.2 -m v2.1.2
if (cd "$artifact_repo" && scripts/build-release-source.sh v2.1.2 "$artifact_out") >"$t/artifact.out" 2>&1; then
  echo 'build unexpectedly accepted a tracked dashboard binary artifact' >&2
  exit 1
fi
grep -F 'dashboard build artifact is forbidden' "$t/artifact.out" >/dev/null

# Retired dashboard source paths must fail closed before they can enter a tag.
retired_repo=$t/retired-repo
retired_out=$t/retired-out
git clone -q "$repo" "$retired_repo"
git -C "$retired_repo" config --local user.email release-test@example.invalid
git -C "$retired_repo" config --local user.name release-test
git -C "$retired_repo" checkout -q v2.1.0
mkdir -p "$retired_repo/src/grafana"
printf 'retired source\n' > "$retired_repo/src/grafana/Dockerfile"
printf '2.3.0\n' > "$retired_repo/VERSION"
git -C "$retired_repo" add VERSION src/grafana/Dockerfile
git -C "$retired_repo" commit -qm 'retired source fixture'
git -C "$retired_repo" tag -a v2.3.0 -m v2.3.0
if (cd "$retired_repo" && scripts/build-release-source.sh v2.3.0 "$retired_out") >"$t/retired.out" 2>&1; then
  echo 'build unexpectedly accepted a retired dashboard source path' >&2
  exit 1
fi
grep -F 'retired dashboard path is forbidden: src/grafana/Dockerfile' "$t/retired.out" >/dev/null

# Each secret-like path is force-added to an otherwise clean tagged checkout;
# the builder must reject it before asking git archive for any paths.
secret_case(){
  name=$1
  path=$2
  secret_repo=$t/secret-$name
  secret_out=$t/secret-out-$name
  git clone -q "$repo" "$secret_repo"
  git -C "$secret_repo" config --local user.email release-test@example.invalid
  git -C "$secret_repo" config --local user.name release-test
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
for dashboard_asset in \
  Dockerfile LICENSE go.mod README.md \
  cmd/dashboard/main.go cmd/dashboard/main_test.go \
  internal/proxy/proxy.go internal/proxy/proxy_test.go \
  internal/ui/ui.go internal/ui/ui_test.go internal/ui/app_state_test.js \
  internal/ui/static/index.html \
  internal/ui/static/assets/app.js internal/ui/static/assets/request-state.js \
  internal/ui/static/assets/styles.css; do
  test -f "$extract/AgentOTelStack-v2.1.0/src/dashboard/$dashboard_asset"
done
cmp "$extract/AgentOTelStack-v2.1.0/LICENSE" "$extract/AgentOTelStack-v2.1.0/src/dashboard/LICENSE"
for contract_input in \
  Makefile README.md AGENTS.md CHANGELOG.md .env.example docker-compose.yml \
  docs/README.md docs/ko/README.md \
  docs/AGENT_SETUP.md docs/ARCHITECTURE.md docs/CONNECT.md docs/DASHBOARD.md \
  docs/DEVELOPMENT.md docs/JSON_CONTRACT.md docs/OPERATIONS.md docs/QUERY.md \
  docs/RELEASING.md docs/REPLACE_SAMPLE_APP.md docs/SAMPLING_AND_COMPLETENESS.md \
  docs/SECURITY.md docs/TROUBLESHOOTING.md \
  docs/ko/AGENT_SETUP.md docs/ko/ARCHITECTURE.md docs/ko/CONNECT.md docs/ko/DASHBOARD.md \
  docs/ko/DEVELOPMENT.md docs/ko/JSON_CONTRACT.md docs/ko/OPERATIONS.md docs/ko/QUERY.md \
  docs/ko/RELEASING.md docs/ko/REPLACE_SAMPLE_APP.md docs/ko/SAMPLING_AND_COMPLETENESS.md \
  docs/ko/SECURITY.md docs/ko/TROUBLESHOOTING.md e2e/package.json e2e/package-lock.json \
  e2e/playwright.config.js scripts/install.sh scripts/uninstall.sh \
  scripts/check-gofmt.sh scripts/check-ci-gate-coverage.sh scripts/release_source_policy.py tests/ci_gate_coverage.json tests/runtime/gofmt_contract.sh tests/runtime/install_hash_tools.sh tests/runtime/ci_supply_chain_cleanup.sh src/gateway/internal/query/query.go src/gateway/internal/query/correlation/correlation.go src/gateway/internal/status/status.go src/gateway/schemas/context.schema.json src/gateway/schemas/correlate.schema.json; do
  test -f "$extract/AgentOTelStack-v2.1.0/$contract_input"
done
for retired_input in docs/DASHBOARD_PLAN.md scripts/benchmark_batch_timeout.sh; do
  if test -e "$extract/AgentOTelStack-v2.1.0/$retired_input" || test -L "$extract/AgentOTelStack-v2.1.0/$retired_input"; then
    echo "deleted source input leaked into source archive: $retired_input" >&2
    exit 1
  fi
done
# This literal verifies the Compose image template in the extracted asset.
# shellcheck disable=SC2016
grep -Fq 'image: dev-observability/dashboard:${AGENTOTEL_RUNTIME_VERSION:-dev}' "$extract/AgentOTelStack-v2.1.0/docker-compose.yml"
if grep -Eqi 'grafana|dashboard-lite' "$extract/AgentOTelStack-v2.1.0/docker-compose.yml"; then
  echo 'retired dashboard configuration leaked into source archive' >&2
  exit 1
fi
export HOME="$t/home"
export XDG_DATA_HOME="$t/data"
export XDG_BIN_HOME="$t/bin"
export XDG_CONFIG_HOME="$t/config"
mkdir -p "$HOME"
"$extract/AgentOTelStack-v2.1.0/scripts/install.sh" --without-mcp 2.1.0 >/dev/null
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 2.1.0
test -s "$XDG_DATA_HOME/agentotel/current/manifest.sha256"

echo 'release source archive checks passed'
