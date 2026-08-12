#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
stream_fields="$(awk '/VL-Stream-Fields:/{print $2}' otel-collector/config.yaml | tr -d '"')"
[[ "$stream_fields" == 'project,service.name,deployment.environment' ]] || { echo "unexpected stream fields: $stream_fields" >&2; exit 1; }
for forbidden in run_id run.id checkout_id checkout.id machine_id machine.id branch commit instance instance_id; do
  grep -A80 'transform/metric-sanitize:' otel-collector/config.yaml | grep -q "delete_key(attributes, \"$forbidden\")" || { echo "cardinality-test: metric sanitizer missing $forbidden" >&2; exit 1; }
done
go_image='golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2'
race_image='golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd'
if command -v go >/dev/null 2>&1; then
  (cd gateway && go test ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1)
  (cd gateway && go test -race ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1)
else
  docker run --rm -v "$PWD/gateway:/src/gateway" -w /src/gateway "$go_image" go test ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1
  docker run --rm -v "$PWD/gateway:/src/gateway" -w /src/gateway "$race_image" go test -race ./internal/query/correlation ./internal/query -run 'TestDecode|TestValidate' -count=1
fi
echo 'cardinality-test: PASS (bounded stream/metric identity and correlation fixture checks; no live backend queried)'
