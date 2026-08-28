#!/usr/bin/env bash
# Black-box runtime proof for the public Gateway security and cardinality
# controls. This test intentionally uses only the app and authenticated,
# bounded Gateway endpoints; it never queries Collector or Victoria directly.
set -Eeuo pipefail

if (( $# != 4 )); then
  echo 'usage: test-runtime-controls.sh APP_URL GATEWAY_URL PROJECT_ID SERVICE' >&2
  exit 2
fi
app_url=${1%/}
gateway_url=${2%/}
project=$3
service=$4
: "${GATEWAY_QUERY_TOKEN:?GATEWAY_QUERY_TOKEN is required}"

[[ "$project" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
  echo 'runtime controls: invalid project UUID' >&2
  exit 2
}
[[ "$service" =~ ^[[:print:]]+$ && "$service" != *[?\&=]* ]] || {
  echo 'runtime controls: invalid service name' >&2
  exit 2
}
for dependency in awk curl grep jq od seq; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "runtime controls: required dependency not found: $dependency" >&2
    exit 1
  }
done

request_count=${RUNTIME_CARDINALITY_REQUESTS:-12}
timeout=${RUNTIME_CONTROLS_TIMEOUT:-90}
[[ "$request_count" =~ ^[0-9]+$ && "$request_count" -ge 1 && "$request_count" -le 50 ]] || {
  echo 'runtime controls: RUNTIME_CARDINALITY_REQUESTS must be 1..50' >&2
  exit 2
}
[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || {
  echo 'runtime controls: RUNTIME_CONTROLS_TIMEOUT must be a positive integer' >&2
  exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-runtime-controls.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

# The canary is sent through query, authorization, and cookie fields so the
# running instrumentation/Collector path has sensitive values to sanitize.
canary="runtime-canary-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$canary" =~ ^runtime-canary-[0-9a-f]{24}$ ]] || {
  echo 'runtime controls: unable to generate canary' >&2
  exit 1
}
headers="$tmp/headers"
body="$tmp/body"
forced_status=$(curl -sS --connect-timeout 5 --max-time 15 \
  -D "$headers" -o "$body" -w '%{http_code}' \
  -H "Authorization: Bearer $canary" \
  -H "Cookie: secret=$canary" \
  --get --data-urlencode 'fail=1' --data-urlencode "secret=$canary" \
  "$app_url/api/checkout") || {
  echo 'runtime controls: canary request failed' >&2
  exit 1
}
trace=$(awk 'tolower($1) == "x-agentotel-trace-id:" { sub(/\r$/, "", $2); print tolower($2); exit }' "$headers")
trace_count=$(awk 'tolower($1) == "x-agentotel-trace-id:" { count++ } END { print count + 0 }' "$headers")
[[ "$forced_status" == 500 && "$trace_count" == 1 && "$trace" =~ ^[0-9a-f]{32}$ ]] || {
  echo 'runtime controls: canary request did not produce one valid forced-error trace' >&2
  exit 1
}

# Generate distinct request identifiers before reading the metric snapshot. The
# sample app attaches these IDs to spans, while the metric contract must retain
# only the bounded outcome dimension.
for n in $(seq 1 "$request_count"); do
  curl -fsS --connect-timeout 5 --max-time 15 \
    "$app_url/api/orders/runtime-cardinality-$n" >/dev/null || {
    echo 'runtime controls: cardinality workload request failed' >&2
    exit 1
  }
done

query_get() {
  local path=$1 output=$2
  shift 2
  curl -sS --connect-timeout 3 --max-time 12 \
    -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get \
    "$gateway_url$path" "$@" >"$output" || return 1
}
query_post_correlate() {
  local output=$1
  curl -sS --connect-timeout 3 --max-time 12 \
    -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" \
    -H 'Content-Type: application/json' -X POST \
    --data "{\"trace_id\":\"$trace\",\"project\":\"$project\",\"limit\":100,\"lookback\":\"5m\"}" \
    "$gateway_url/v1/correlate" >"$output" || return 1
}

safe_response() {
  local file=$1
  # Check both values and keys. A projected response must not expose sensitive
  # field names even when the canary itself was not captured by instrumentation.
  ! grep -Fq -- "$canary" "$file" || return 1
  ! grep -Fq -- "$GATEWAY_QUERY_TOKEN" "$file" || return 1
  jq -e '
    [.. | objects | keys[]? | ascii_downcase
      | select(test("authorization|cookie|password|secret|token|api[_-]?key|url|query|body"))]
    | length == 0
  ' "$file" >/dev/null
}

correlation_ok() {
  jq -e --arg trace "$trace" '
    .schema_version == "1.0" and .partial == false and
    .content_trust == "untrusted_telemetry" and
    .data.correlation.trace_id == $trace and
    ((.data.correlation.spans // []) | length > 0) and
    (.data.correlation.logs != null) and
    (.data.correlation.metrics != null) and
    ([.data.correlation.logs[]? | select(.trace_id == $trace)] | length > 0)
  ' "$1" >/dev/null
}
errors_ok() {
  jq -e --arg trace "$trace" '
    .schema_version == "1.0" and .partial == false and
    ([.. | objects | select((.trace_id // .traceID // empty) == $trace)] | length > 0)
  ' "$1" >/dev/null
}
context_metrics_ok() {
  jq -e '
    .schema_version == "1.0" and .partial == false and
    .data.metrics.status == "success" and
    (.data.metrics.data.resultType == "vector" or .data.metrics.data.resultType == "matrix") and
    ((.data.metrics.data.result // []) | length > 0) and
    ([.data.metrics.data.result[]?.metric // {} | keys[]?] as $keys |
      ($keys | length > 0) and ($keys | all(. == "service_name")))
  ' "$1" >/dev/null
}

correlation_file="$tmp/correlation"
errors_file="$tmp/errors"
context_file="$tmp/context"
deadline=$(( $(date +%s) + timeout ))
ready=0
while (( $(date +%s) < deadline )); do
  query_post_correlate "$correlation_file" || :
  query_get /v1/errors "$errors_file" \
    --data-urlencode "service=$service" --data-urlencode "project=$project" \
    --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || :
  query_get /v1/context "$context_file" \
    --data-urlencode "service=$service" --data-urlencode "project=$project" \
    --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || :
  if correlation_ok "$correlation_file" && errors_ok "$errors_file" && context_metrics_ok "$context_file"; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  echo 'runtime controls: live Gateway evidence did not become complete before timeout' >&2
  exit 1
}

for response in "$correlation_file" "$errors_file" "$context_file"; do
  safe_response "$response" || {
    echo 'runtime controls: live Gateway response exposed a sensitive value or field' >&2
    exit 1
  }
done
metric_rows=$(jq -r '.data.metrics.data.result | length' "$context_file")
printf 'runtime controls: PASS (live Gateway redaction, exact trace correlation, and bounded metric labels; rows=%s canary=withheld)\n' "$metric_rows"
