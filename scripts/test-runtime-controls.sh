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
for dependency in awk curl grep jq od python3 seq; do
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

freshness_ok() {
  local file=$1 value
  value=$(jq -er '.freshness' "$file") || return 1
  python3 - "$value" <<'PY'
from datetime import datetime
import re
import sys
import time

raw = sys.argv[1].replace("Z", "+00:00")
match = re.fullmatch(r"(.*\.)([0-9]+)([+-][0-9]{2}:[0-9]{2})", raw)
if match:
    raw = match.group(1) + match.group(2)[:6].ljust(6, "0") + match.group(3)
try:
    value = datetime.fromisoformat(raw)
except ValueError:
    raise SystemExit(1)
if value.tzinfo is None or abs(time.time() - value.timestamp()) > 120:
    raise SystemExit(1)
PY
}
metadata_ok() {
  local file=$1 kind=$2 expected_project=$3 expected_service=$4 expected_trace=$5 limit=$6
  jq -e --arg kind "$kind" --arg project "$expected_project" --arg service "$expected_service" --arg trace "$expected_trace" --argjson limit "$limit" '
    .schema_version == "1.0" and .kind == $kind and
    .partial == false and .truncated == false and
    .content_trust == "untrusted_telemetry" and
    (.scope.project // "") == $project and
    (.scope.service // "") == $service and
    (.scope.trace_id // "") == $trace and
    .scope.lookback == "5m" and .scope.limit == $limit and
    ([.backends[]?.status] | length > 0 and all(. == "ok"))
  ' "$file" >/dev/null && freshness_ok "$file"
}
correlation_ok() {
  metadata_ok "$1" gateway.correlate.v1 "$project" "" "$trace" 100 &&
  jq -e --arg trace "$trace" '
    def trace_value: .trace_id // .traceID // .traceId // .traceid // "";
    .data.correlation.trace_id == $trace and
    ((.data.correlation.spans // []) | length > 0) and
    ((.data.correlation.logs // []) | length > 0) and
    (((.data.correlation.metrics.data.result // []) | length > 0) or
      ((.data.correlation.metrics.result // []) | length > 0)) and
    ([.data.correlation.logs[]? | select(trace_value == $trace)] | length > 0)
  ' "$1" >/dev/null
}
errors_ok() {
  metadata_ok "$1" gateway.errors.v1 "$project" "$service" "" 100 &&
  jq -e --arg trace "$trace" '
    def trace_value: .trace_id // .traceID // .traceId // .traceid // "";
    ([.data.logs, .data.traces] | [.. | objects | select(trace_value == $trace)] | length > 0)
  ' "$1" >/dev/null
}
context_metrics_ok() {
  metadata_ok "$1" gateway.context.v1 "$project" "$service" "" 100 &&
  jq -e '
    .data.metrics.status == "success" and
    .data.metrics.data.resultType == "vector" and
    ((.data.metrics.data.result // []) | length > 0) and
    ([.data.metrics.data.result[]?.metric // {} | keys[]?] as $keys |
      ($keys | length > 0) and ($keys | all(. == "service_name")) and
      ([.data.metrics.data.result[]?.metric.service_name] | all(. == "sample-app")))
  ' "$1" >/dev/null
}
negative_scope_ok() {
  local file=$1 kind=$2 expected_project=$3 expected_service=$4
  jq -e --arg kind "$kind" --arg project "$expected_project" --arg service "$expected_service" '
    def trace_value: .trace_id // .traceID // .traceId // .traceid // "";
    .schema_version == "1.0" and .kind == $kind and
    .partial == false and .truncated == false and
    .content_trust == "untrusted_telemetry" and
    (.scope.project // "") == $project and (.scope.service // "") == $service and
    ([.data.logs, .data.traces, .data.metrics, .data.correlation] |
      [.. | objects | select(trace_value != "")] | length == 0)
  ' "$file" >/dev/null && freshness_ok "$file"
}

debug_response() {
  local label=$1 file=$2
  if ! jq -c --arg trace "$trace" '
    def trace_value: .trace_id // .traceID // .traceId // .traceid // "";
    {
      schema_version,
      kind,
      partial,
      truncated,
      freshness: (.freshness // null),
      expected_trace: $trace,
      scope: (.scope // {}),
      content_trust,
      backend_statuses: [.backends[]?.status],
      data_keys: ((.data // {}) | keys),
      correlation_counts: {
        spans: ((.data.correlation.spans // []) | if type == "array" then length else -1 end),
        logs: ((.data.correlation.logs // []) | if type == "array" then length else -1 end),
        log_trace_matches: ([.data.correlation.logs[]? | select(trace_value == $trace)] | length),
        metrics: (((.data.correlation.metrics.data.result // .data.correlation.metrics.result // []) | if type == "array" then length else -1 end))
      },
      context_metrics: {
        status: (.data.metrics.status // null),
        result_type: (.data.metrics.data.resultType // null),
        result_count: ((.data.metrics.data.result // []) | if type == "array" then length else -1 end),
        label_keys: ([.data.metrics.data.result[]?.metric // {} | keys[]?] | unique),
        service_names: [.data.metrics.data.result[]?.metric.service_name]
      },
      error_counts: {
        logs: ((.data.logs // []) | if type == "array" then length else -1 end),
        traces: ((.data.traces // []) | if type == "array" then length else -1 end),
        trace_matches: ([.data.logs, .data.traces] |
          [.. | objects | select(trace_value == $trace)] | length)
      }
    }
  ' "$file" >&2; then
    printf 'runtime controls: %s response was not valid JSON\n' "$label" >&2
  fi
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
  correlation_state=fail
  errors_state=fail
  context_state=fail
  if correlation_ok "$correlation_file"; then correlation_state=pass; fi
  if errors_ok "$errors_file"; then errors_state=pass; fi
  if context_metrics_ok "$context_file"; then context_state=pass; fi
  if [[ "$correlation_state" == pass && "$errors_state" == pass && "$context_state" == pass ]]; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  echo 'runtime controls: live Gateway evidence did not become complete before timeout' >&2
  printf 'runtime controls: predicate states correlation=%s errors=%s context=%s\n' \
    "$correlation_state" "$errors_state" "$context_state" >&2
  debug_response correlation "$correlation_file"
  debug_response errors "$errors_file"
  debug_response context "$context_file"
  exit 1
}

for response in "$correlation_file" "$errors_file" "$context_file"; do
  safe_response "$response" || {
    echo 'runtime controls: live Gateway response exposed a sensitive value or field' >&2
    exit 1
  }
done

# Negative scope probes prove that the positive evidence was not satisfied by a
# service-name match or an older project snapshot. They use the same bounded
# authenticated Gateway path and retain the normal envelope checks.
wrong_project=00000000-0000-4000-8000-000000000003
wrong_project_file="$tmp/wrong-project"
wrong_service_file="$tmp/wrong-service"
query_get /v1/errors "$wrong_project_file" \
  --data-urlencode "service=$service" --data-urlencode "project=$wrong_project" \
  --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || {
  echo 'runtime controls: wrong-project probe request failed' >&2
  exit 1
}
query_get /v1/context "$wrong_service_file" \
  --data-urlencode 'service=runtime-service-that-does-not-exist' --data-urlencode "project=$project" \
  --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || {
  echo 'runtime controls: wrong-service probe request failed' >&2
  exit 1
}
negative_scope_ok "$wrong_project_file" gateway.errors.v1 "$wrong_project" "$service" || {
  echo 'runtime controls: wrong-project response contained scoped telemetry or invalid metadata' >&2
  exit 1
}
negative_scope_ok "$wrong_service_file" gateway.context.v1 "$project" 'runtime-service-that-does-not-exist' || {
  echo 'runtime controls: wrong-service response contained scoped telemetry or invalid metadata' >&2
  exit 1
}
safe_response "$wrong_project_file" || { echo 'runtime controls: wrong-project response failed redaction' >&2; exit 1; }
safe_response "$wrong_service_file" || { echo 'runtime controls: wrong-service response failed redaction' >&2; exit 1; }

metric_rows=$(jq -r '.data.metrics.data.result | length' "$context_file")
printf 'runtime controls: PASS (live Gateway redaction, exact trace/project/service evidence, freshness, and bounded metric labels; rows=%s canary=withheld)\n' "$metric_rows"
