#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
version_lines=$(awk 'END { print NR }' VERSION)
[ "$version_lines" -eq 1 ] || { echo 'VERSION must contain exactly one line' >&2; exit 1; }
expected=$(cat VERSION)
printf '%s\n' "$expected" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
  echo "VERSION must be a strict core SemVer (MAJOR.MINOR.PATCH): $expected" >&2
  exit 1
}
check_schema(){ actual=$1; path=$2; [ "$actual" = "1.0" ] || { echo "schema mismatch: $path=$actual expected=1.0" >&2; exit 1; }; }

release_tag=
tag_context=0
if [ -n "${RELEASE_TAG:-}" ]; then
  release_tag=$RELEASE_TAG
  tag_context=1
elif case "${GITHUB_REF:-}" in refs/tags/*) true;; *) false;; esac; then
  release_tag=${GITHUB_REF#refs/tags/}
  tag_context=1
fi
if [ "$tag_context" -eq 1 ] && [ "$release_tag" != "v$expected" ]; then
  echo "release tag mismatch: $release_tag expected v$expected" >&2
  exit 1
fi

changelog_heading='## 2.1.0 — 2026-08-14'
first_heading=$(awk '/^## / { print; exit }' CHANGELOG.md)
[ "$first_heading" = "$changelog_heading" ] || {
  echo "first CHANGELOG release heading must be: $changelog_heading" >&2
  exit 1
}
changelog_section=$(awk -v heading="$changelog_heading" '
  /^## / {
    if (in_section) exit
    if ($0 == heading) { in_section=1; next }
  }
  in_section { print }
' CHANGELOG.md)
printf '%s\n' "$changelog_section" | grep -q '[^[:space:]]' || {
  echo 'the first CHANGELOG release section must be nonempty' >&2
  exit 1
}
for changelog_term in \
  'post[-[:space:]]+2\.0\.1' \
  'dependenc(y|ies)' \
  'runtime' \
  'src/' \
  '\.agentotel/' \
  'release[[:space:]-]+pipeline'; do
  printf '%s\n' "$changelog_section" | grep -Eiq "$changelog_term" || {
    echo "first CHANGELOG release section is missing: $changelog_term" >&2
    exit 1
  }
done

python3 - "$expected" <<'PY'
import json
import sys

expected = sys.argv[1]
for filename in ("src/app/package.json", "e2e/package.json"):
    with open(filename, encoding="utf-8") as handle:
        document = json.load(handle)
    actual = document.get("version")
    if actual != expected:
        raise SystemExit(f"version mismatch: {filename}={actual} expected={expected}")

for filename in ("src/app/package-lock.json", "e2e/package-lock.json"):
    with open(filename, encoding="utf-8") as handle:
        document = json.load(handle)
    checks = (
        ("top-level version", document.get("version")),
        ("packages[''] version", document.get("packages", {}).get("", {}).get("version")),
    )
    for field, actual in checks:
        if actual != expected:
            raise SystemExit(f"version mismatch: {filename} {field}={actual} expected={expected}")
PY

grep -q '"gateway_version": gatewayVersion()' src/gateway/cmd/gateway/main.go || { echo 'Gateway version must use the runtime/build version' >&2; exit 1; }
if ! grep -q 'GATEWAY_VERSION:' docker-compose.yml || ! grep -q 'AGENTOTEL_RUNTIME_VERSION' docker-compose.yml; then
  echo 'Compose must inject the selected runtime version into Gateway' >&2
  exit 1
fi
grep -q 'serverInfo.*version.*buildVersion' src/mcp/main.go || { echo 'MCP serverInfo must use the injected build version' >&2; exit 1; }
grep -q 'main.buildVersion' scripts/build-mcp.sh || { echo 'MCP build must inject the runtime version' >&2; exit 1; }
gateway_main=src/gateway/cmd/gateway/main.go
check_schema "$(sed -n 's/.*api_min": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_api_min
check_schema "$(sed -n 's/.*api_max": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_api_max
check_schema "$(sed -n 's/.*schema_version": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_schema_version
for f in src/gateway/schemas/*.json; do
  [ -f "$f" ] || continue
  flat=$(tr '\n' ' ' < "$f")
  schema_const=$(printf '%s\n' "$flat" | sed -n 's/.*"schema_version"[[:space:]]*:[[:space:]]*{[[:space:]]*"const"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$schema_const" ] || continue
  check_schema "$schema_const" "$f schema_version"
done
echo "release version: $expected"
