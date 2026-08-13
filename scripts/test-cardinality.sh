#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
stream_fields="$(awk '/VL-Stream-Fields:/{print $2}' src/otel-collector/config.yaml | tr -d '"')"
[[ "$stream_fields" == 'project,service.name,deployment.environment' ]] || { echo "unexpected stream fields: $stream_fields" >&2; exit 1; }
grep -A12 'transform/metric-sanitize:' src/otel-collector/config.yaml | grep -Fq 'keep_keys(attributes, ["outcome"])' || { echo 'cardinality-test: metric sanitizer must allowlist outcome' >&2; exit 1; }
grep -A12 'transform/resource-allowlist:' src/otel-collector/config.yaml | grep -Fq 'keep_keys(resource.attributes, ["project", "service.name", "deployment.environment"])' || { echo 'cardinality-test: resource sanitizer must use the bounded allowlist' >&2; exit 1; }
metric_block="$(awk '/^  transform\/metric-sanitize:/{seen=1} seen && /^  [^[:space:]][^:]*:/{if ($0 !~ /transform\/metric-sanitize:/) exit} seen{print}' src/otel-collector/config.yaml)"
if printf '%s\n' "$metric_block" | grep -Fq 'delete_key(attributes,'; then
  echo 'cardinality-test: metric sanitizer must not duplicate deletes after allowlist' >&2
  exit 1
fi
go_image='golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2'
race_image='golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd'
if command -v go >/dev/null 2>&1; then
  (cd src/gateway && go test ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1)
  (cd src/gateway && go test -race ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1)
else
  docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$go_image" go test ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1
  docker run --rm -v "$PWD/src/gateway:/src/gateway" -w /src/gateway "$race_image" go test -race ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1
fi
echo 'cardinality-test: PASS (bounded stream/metric identity and correlation fixture checks; no live backend queried)'
