#!/bin/sh
set -eu

# Build the source artifact for an already checked-out release tag.  The
# archive is intentionally made from the tag's commit, never from the working
# tree: this keeps ignored build output and local edits out of release assets.
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

# GitHub exposes refs/tags/vX.Y.Z in GITHUB_REF.  Accepting the short name is
# useful locally; the tag and the checked-out commit remain the source of truth
# for this artifact.
case "$tag" in
  refs/tags/*) tag=${tag#refs/tags/};;
esac
case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "invalid release tag: $tag (expected vX.Y.Z)";;
esac
version=${tag#v}
case "$version" in
  ''|*[!0-9.]*|*.*.*.*|.*|*.|*..*) fail "invalid release version: $version";;
esac
major=${version%%.*}
version_tail=${version#*.}
minor=${version_tail%%.*}
patch_version=${version_tail#*.}
case "$major:$minor:$patch_version" in
  0[0-9]*:*|*:0[0-9]*:*|*:*:0[0-9]*) fail "invalid release version: $version";;
esac

git show-ref --verify --quiet "refs/tags/$tag" || fail "tag does not exist: $tag"
commit=$(git rev-parse --verify "$tag^{commit}" 2>/dev/null) || fail "tag does not resolve to a commit: $tag"
head=$(git rev-parse --verify HEAD 2>/dev/null) || fail 'unable to resolve checkout HEAD'
[ "$commit" = "$head" ] || fail "checkout HEAD $head does not match tag $tag commit $commit"

version_at_tag=$(git show "$commit:VERSION" 2>/dev/null) || fail 'tagged commit has no VERSION file'
case "$version_at_tag" in
  "$version") :;;
  *) fail "tagged VERSION is $version_at_tag, expected $version";;
esac

entries=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-entries.XXXXXX")
names=$(mktemp "${TMPDIR:-/tmp}/agentotel-release-names.XXXXXX")
staging=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release.XXXXXX")
cleanup(){ rm -f "$entries" "$names"; rm -rf "$staging"; }
trap cleanup EXIT HUP INT TERM

# The source artifact is intentionally an explicit allowlist.  In particular,
# CI metadata and local/secret state are not implicitly included just because
# they happen to be tracked in the repository.
allowlist='.env.example .gitignore .gitleaks.toml AGENTS.md CLAUDE.md CHANGELOG.md LICENSE Makefile README.md VERSION docker-compose.yml bin libexec obs workload scripts security tests docs e2e src'
required='VERSION LICENSE README.md CHANGELOG.md .env.example docker-compose.yml bin/obs scripts/install.sh scripts/uninstall.sh libexec/agentotel/dispatch.sh src/app/Dockerfile src/app/package.json src/app/package-lock.json src/backend-health/Dockerfile.collector src/backend-health/Dockerfile.victorialogs src/backend-health/Dockerfile.victoriametrics src/backend-health/Dockerfile.victoriatraces src/backend-health/health.go src/gateway/Dockerfile src/gateway/go.mod src/gateway/cmd/gateway/main.go src/mcp/go.mod src/mcp/main.go src/otel-collector/config.yaml src/grafana/Dockerfile src/dashboards/local-observability.json'

git ls-tree -r "$commit" > "$entries" || fail 'unable to inspect tagged tree'
git ls-tree -r --name-only "$commit" > "$names" || fail 'unable to inspect tagged paths'
while IFS='	' read -r meta path; do
  [ -n "$path" ] || continue
  mode=${meta%% *}
  case "$mode" in
    100644|100755) :;;
    120000)
      link_target=$(git show "$commit:$path" 2>/dev/null) || fail "unable to inspect symlink: $path"
      case "$link_target" in
        ''|/*|*\\*|*:) fail "unsafe tracked symlink: $path -> $link_target";;
      esac
      case "/$link_target/" in
        */../*|*/./*|*//*|*:*) fail "unsafe tracked symlink: $path -> $link_target";;
      esac
      link_dir=${path%/*}
      if [ "$link_dir" = "$path" ]; then
        link_path=$link_target
      else
        link_path=$link_dir/$link_target
      fi
      grep -Fx "$link_path" "$names" >/dev/null 2>&1 || fail "tracked symlink target is missing: $path -> $link_target"
      ;;
    *) fail "unsupported tracked entry mode $mode: $path";;
  esac
  case "$path" in
    .env.example|*/.env.example) :;;
    .env|*/.env|.env.*|*/.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.crt|*.cer|*/credentials|*/credentials/*|credentials|credentials/*|*/secrets|*/secrets/*|secrets|secrets/*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*|.aws|.aws/*|*/.aws|*/.aws/*|.kube|.kube/*|*/.kube|*/.kube/*)
      fail "tracked secret-like path is forbidden: $path";;
    .agentotel|.agentotel/*|*/.agentotel|*/.agentotel/*|.git|.git/*|*/.git|*/.git/*|*/node_modules|*/node_modules/*|node_modules|node_modules/*|.cache|.cache/*|*/.cache|*/.cache/*|.trivy-cache|.trivy-cache/*|artifacts|artifacts/*|*/artifacts|*/artifacts/*|coverage|coverage/*|*/coverage|*/coverage/*|manifest.sha256|*/manifest.sha256|*.log|*.out|*.prof|*.test|*.coverage|bin/agentotel-mcp|bin/agentotel-mcp-*|src/mcp/mcp|src/*/bin/*)
      fail "tracked generated output is forbidden: $path";;
  esac
done < "$entries"

for path in $allowlist; do
  git cat-file -e "$commit:$path" 2>/dev/null || fail "allowlisted release path is missing: $path"
done
for path in $required; do
  grep -Fx "$path" "$names" >/dev/null 2>&1 || fail "required release file is missing: $path"
done

archive_name="AgentOTelStack-v${version}.tar.gz"
checksum_name="${archive_name}.sha256"
mkdir -p "$out"
[ -d "$out" ] || fail "output path is not a directory: $out"
archive_tmp="$staging/$archive_name"
checksum_tmp="$staging/$checksum_name"

# git archive gives stable file ordering and commit timestamps; gzip -n omits
# the compressor timestamp and host name.  Together they make this byte-for-
# byte reproducible for one commit.
# The allowlist is intentionally expanded into separate path arguments.
# shellcheck disable=SC2086
git archive --format=tar --prefix="AgentOTelStack-v${version}/" "$commit" $allowlist | gzip -n > "$archive_tmp" || fail 'unable to create source archive'

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
hash=$(hash_file "$archive_tmp") || fail 'unable to calculate archive checksum'
printf '%s  %s\n' "$hash" "$archive_name" > "$checksum_tmp"

# The verifier performs the independent tar/root/safety checks before either
# final output is replaced.
"$root/scripts/verify-release-source.sh" --version "$version" "$archive_tmp" "$checksum_tmp" || fail 'generated archive did not pass verification'
mv -f "$archive_tmp" "$out/$archive_name"
mv -f "$checksum_tmp" "$out/$checksum_name"
echo "built $out/$archive_name"
echo "built $out/$checksum_name"
