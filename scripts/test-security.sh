#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SECURITY_CANARY:=auth-canary-cookie-password-token}"
export SECURITY_CANARY
go_image='golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df'
race_image='golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36'
config='src/otel-collector/config.yaml'
for dependency in awk grep rg; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "security-test: required dependency not found: $dependency" >&2
    exit 1
  fi
done

extract_processor() {
  local processor="$1"
  awk -v processor="$processor" '
    $0 == "  transform/" processor ":" { in_processor = 1 }
    in_processor && $0 ~ /^  [^[:space:]][^:]*:/ && $0 != "  transform/" processor ":" { exit }
    in_processor { print }
  ' "$config"
}

assert_processor_contains() {
  local processor="$1"
  local statement="$2"
  local block
  block="$(extract_processor "$processor")"
  if [[ -z "$block" ]]; then
    echo "security-test: missing collector processor: $processor" >&2
    exit 1
  fi
  if ! grep -Fq -- "$statement" <<<"$block"; then
    echo "security-test: $processor must contain: $statement" >&2
    exit 1
  fi
}

for processor in log-sanitize trace-sanitize; do
  assert_processor_contains "$processor" 'delete_key(attributes, "url.query")'
  assert_processor_contains "$processor" 'delete_key(attributes, "url.fragment")'
done
for statement in \
  'replace_pattern(attributes["http.url"], "[?#].*$"' \
  'replace_pattern(attributes["http.target"], "[?#].*$"' \
  'replace_pattern(attributes["url.full"], "[?#].*$"'; do
  if ! grep -Fq -- "$statement" "$config"; then
    echo "security-test: existing URL redaction must remain: $statement" >&2
    exit 1
  fi
done

go_test=(docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$go_image" go test ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
if command -v go >/dev/null 2>&1; then
  (cd src/gateway && go test ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
  (cd src/gateway && go test -race ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1)
else
  "${go_test[@]}"
  docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$race_image" go test -race ./... -run 'Test(ProjectIsSafeForUntrustedTelemetry|AuthIsUniform|IngestForwards|BodyAndContent|LoadRejects|TokenFile)' -count=1
fi
log_scan_status=0
rg -n 'log\.Printf.*(body|token|Authorization|Cookie)|fmt\.Print.*(secret|password|token)' src/gateway --glob '*.go' || log_scan_status=$?
case "$log_scan_status" in
  0)
    echo 'security-test: possible secret-bearing log statement' >&2
    exit 1
    ;;
  1)
    ;;
  *)
    echo "security-test: source scan failed (rg status $log_scan_status)" >&2
    exit 1
    ;;
esac
echo 'security-test: PASS (hermetic gateway projection/auth/log/collector-redaction checks; no live backend queried)'
