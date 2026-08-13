#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SECURITY_CANARY:=auth-canary-cookie-password-token}"
export SECURITY_CANARY
go_image='golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2'
race_image='golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd'
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
