#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
expected=$(cat VERSION)
[ -n "$expected" ] || { echo 'VERSION is empty' >&2; exit 1; }
check(){ actual=$1; path=$2; [ "$actual" = "$expected" ] || { echo "version mismatch: $path=$actual expected=$expected" >&2; exit 1; }; }
check_schema(){ actual=$1; path=$2; [ "$actual" = "1.0" ] || { echo "schema mismatch: $path=$actual expected=1.0" >&2; exit 1; }; }
check "$(sed -n 's/.*gateway_version": "\([^"]*\)".*/\1/p' gateway/cmd/gateway/main.go)" gateway_version
check "$(sed -n 's/.*serverInfo.*version.*: "\([^"]*\)".*/\1/p' mcp/main.go)" mcp
gateway_main=gateway/cmd/gateway/main.go
check_schema "$(sed -n 's/.*api_min": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_api_min
check_schema "$(sed -n 's/.*api_max": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_api_max
check_schema "$(sed -n 's/.*schema_version": "\([^"]*\)".*/\1/p' "$gateway_main")" gateway_schema_version
for f in gateway/schemas/*.json; do
  [ -f "$f" ] || continue
  flat=$(tr '\n' ' ' < "$f")
  schema_const=$(printf '%s\n' "$flat" | sed -n 's/.*"schema_version"[[:space:]]*:[[:space:]]*{[[:space:]]*"const"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$schema_const" ] || continue
  check_schema "$schema_const" "$f schema_version"
done
for f in app/package.json e2e/package.json; do check "$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$f" | head -1)" "$f"; done
for f in app/package-lock.json e2e/package-lock.json; do check "$(sed -n '3s/.*"version": "\([^"]*\)".*/\1/p' "$f")" "$f"; done
echo "release version: $expected"
