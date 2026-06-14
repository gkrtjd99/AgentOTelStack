#!/usr/bin/env bash
# Correlate a single trace across all three signals — the core agent move.
# Given a trace_id, fetch its spans (VictoriaTraces), every log line that
# carries that trace_id (VictoriaLogs), and a same-service metrics snapshot
# (VictoriaMetrics). This is how an agent goes from
# "something is slow/broken" to "here is the exact code path + log context".
#
# Usage:
#   obs/correlate.sh <traceID> [logs-lookback]
#   obs/correlate.sh --soft <traceID> [logs-lookback]
#
# Example:
#   obs/correlate.sh 7f3a2b9c... 1h

source "$(dirname "$0")/common.sh"

soft=false
if [[ "${1:-}" == "--soft" ]]; then
  soft=true
  shift
fi

tid="${1:?usage: correlate.sh <traceID> [logs-lookback]}"
lookback="$(duration_value "${2:-1h}")"
metric_window="$(duration_value "${METRIC_WINDOW:-5m}")"
trace_json="$(mktemp)"

trap 'rm -f "${trace_json}"' EXIT

echo "=== TRACE ${tid} ==="
curl -s "${VT_URL}/select/jaeger/api/traces/${tid}" > "${trace_json}"
if command -v jq >/dev/null 2>&1 && ! jq -e '(.data // []) | length > 0' "${trace_json}" >/dev/null 2>&1; then
  pp < "${trace_json}"
  if [[ "${soft}" == true ]]; then
    exit 0
  fi
  die "trace not found: ${tid}"
fi

if command -v jq >/dev/null 2>&1; then
  jq '.data[0].spans[] | {op: .operationName, durMs: (.duration/1000), tags: ([.tags[] | select(.key=="error" or .key=="http.status_code")])}' "${trace_json}" 2>/dev/null \
    || pp < "${trace_json}"
else
  cat "${trace_json}"
fi

echo
echo "=== LOGS with trace_id=${tid} (last ${lookback}) ==="
log_tid="$(log_field_value "${tid}")"
curl -s "${VL_URL}/select/logsql/query" \
  --data-urlencode "query=_time:${lookback} trace_id:${log_tid}" \
  --data-urlencode "limit=100"

echo
echo "=== METRICS snapshot for traced service(s) ==="
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to derive service names from the trace; skipping metrics snapshot"
  exit 0
fi

services="$(
  jq -r '
    .data[0] as $trace
    | ($trace.spans // [])
    | .[].processID
    ' "${trace_json}" 2>/dev/null |
    sort -u |
    while IFS= read -r pid; do
      jq -r --arg pid "${pid}" '.data[0].processes[$pid].serviceName // empty' "${trace_json}" 2>/dev/null
    done |
    sort -u
)"

if [[ -z "${services}" ]]; then
  echo "no service name found in trace response; skipping metrics snapshot"
  exit 0
fi

metric_query() {
  curl -s "${VM_URL}/api/v1/query" --data-urlencode "query=$1" | pp '.data.result'
}

while IFS= read -r svc; do
  [[ -n "${svc}" ]] || continue
  svc_label="$(prom_label_value "${svc}")"

  echo
  echo "--- service_name=${svc} ---"
  echo "metric names carrying service_name:"
  metric_query "count by (__name__) ({service_name=\"${svc_label}\"})"
  echo
  echo "orders_processed_total by outcome, if present:"
  metric_query "sum by (outcome) (orders_processed_total{service_name=\"${svc_label}\"})"
  echo
  echo "orders error ratio from current counters, if present:"
  metric_query "sum(orders_processed_total{service_name=\"${svc_label}\",outcome=\"error\"}) / clamp_min(sum(orders_processed_total{service_name=\"${svc_label}\"}), 1)"
  echo
  echo "order latency p95 over last ${metric_window}, if present:"
  metric_query "histogram_quantile(0.95, sum by (le) (increase(order_processing_seconds_bucket{service_name=\"${svc_label}\"}[${metric_window}])))"
done <<< "${services}"
