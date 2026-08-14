#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SECURITY_CANARY:=auth-canary-cookie-password-token}"
export SECURITY_CANARY
go_image='golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df'
race_image='golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36'
go_test=(docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$go_image" go test ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
if command -v go >/dev/null 2>&1; then
  (cd src/gateway && go test ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
  (cd src/gateway && go test -race ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
else
  "${go_test[@]}"
  docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$race_image" go test -race ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1
fi
if rg -n 'log\.Printf.*(body|token|Authorization|Cookie)|fmt\.Print.*(secret|password|token)' src/gateway --glob '*.go'; then
  echo 'security-test: possible secret-bearing log statement' >&2; exit 1
fi
echo 'security-test: PASS (hermetic gateway projection/auth/log checks; no live backend queried)'
