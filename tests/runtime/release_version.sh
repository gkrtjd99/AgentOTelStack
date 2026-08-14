#!/bin/sh
set -eu

root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-release-version.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/scripts" \
  "$fixture/src/app" \
  "$fixture/e2e" \
  "$fixture/src/gateway/cmd/gateway" \
  "$fixture/src/gateway/schemas" \
  "$fixture/src/mcp"
cp "$root/VERSION" "$root/CHANGELOG.md" "$fixture/"
cp "$root/docker-compose.yml" "$fixture/"
cp "$root/scripts/verify-release-version.sh" "$root/scripts/build-mcp.sh" "$fixture/scripts/"
cp "$root/src/app/package.json" "$root/src/app/package-lock.json" "$fixture/src/app/"
cp "$root/e2e/package.json" "$root/e2e/package-lock.json" "$fixture/e2e/"
cp "$root/src/gateway/cmd/gateway/main.go" "$fixture/src/gateway/cmd/gateway/"
cp "$root/src/gateway/schemas/"*.json "$fixture/src/gateway/schemas/"
cp "$root/src/mcp/main.go" "$fixture/src/mcp/"

run_fixture() {
  (cd "$fixture" && env "$@" ./scripts/verify-release-version.sh >/dev/null 2>&1)
}

# A normal branch and both supported release-tag contexts are valid.
run_fixture GITHUB_REF=refs/heads/release-2.1.0
run_fixture RELEASE_TAG=v2.1.0 GITHUB_REF=refs/heads/main
run_fixture GITHUB_REF=refs/tags/v2.1.0

# A tag context must identify this exact release.
if run_fixture RELEASE_TAG=v2.1.1; then
  echo 'release verifier accepted a mismatched RELEASE_TAG' >&2
  exit 1
fi
if run_fixture GITHUB_REF=refs/tags/v2.1.1; then
  echo 'release verifier accepted a mismatched GITHUB_REF tag' >&2
  exit 1
fi
if run_fixture GITHUB_REF=refs/tags/; then
  echo 'release verifier accepted an empty GITHUB_REF tag' >&2
  exit 1
fi

# Each lockfile version location is checked independently.
sed '3s/2.1.0/2.1.1/' "$fixture/src/app/package-lock.json" >"$fixture/src/app/package-lock.tmp"
mv "$fixture/src/app/package-lock.tmp" "$fixture/src/app/package-lock.json"
if run_fixture; then
  echo 'release verifier accepted a mismatched lockfile top-level version' >&2
  exit 1
fi
cp "$root/src/app/package-lock.json" "$fixture/src/app/package-lock.json"
sed '9s/2.1.0/2.1.1/' "$fixture/src/app/package-lock.json" >"$fixture/src/app/package-lock.tmp"
mv "$fixture/src/app/package-lock.tmp" "$fixture/src/app/package-lock.json"
if run_fixture; then
  echo 'release verifier accepted a mismatched lockfile packages[""].version' >&2
  exit 1
fi

# Core SemVer rejects prerelease/build suffixes and leading-zero components.
printf '%s\n' '2.1.0-rc.1' >"$fixture/VERSION"
if run_fixture; then
  echo 'release verifier accepted a non-core VERSION' >&2
  exit 1
fi
printf '%s\n' '02.1.0' >"$fixture/VERSION"
if run_fixture; then
  echo 'release verifier accepted a leading-zero VERSION' >&2
  exit 1
fi

echo 'release-version fixture: PASS'
