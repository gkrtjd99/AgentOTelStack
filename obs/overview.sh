#!/usr/bin/env bash
# Human- and agent-readable terminal dashboard for one service.

source "$(dirname "$0")/common.sh"

usage() {
  cat <<'EOF'
Usage:
  obs/overview.sh [--compact] [--json] [--lookback 15m|--since 15m] [--limit 5] [service]
  obs/overview.sh [service] [lookback]

Examples:
  obs/overview.sh sample-app
  obs/overview.sh --compact --lookback 30m sample-app
  obs/overview.sh --json --since 15m sample-app
EOF
}

json_mode=0
compact=0
svc="sample-app"
lookback="15m"
limit="5"
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      json_mode=1
      ;;
    --compact)
      compact=1
      ;;
    --lookback|--since)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      lookback="$(duration_value "$1")"
      ;;
    --limit)
      shift
      [[ $# -gt 0 ]] || die "--limit requires a value"
      limit="$(limit_value "$1")"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      ;;
  esac
  shift
done

if [[ ${#positional[@]} -gt 0 ]]; then
  svc="${positional[0]}"
fi
if [[ ${#positional[@]} -gt 1 ]]; then
  lookback="$(duration_value "${positional[1]}")"
fi
if [[ ${#positional[@]} -gt 2 ]]; then
  die "too many positional arguments"
fi

require_jq

dir="$(dirname "$0")"
svc_label="$(prom_label_value "${svc}")"

metric_query() {
  curl -s "${VM_URL}/api/v1/query" --data-urlencode "query=$1"
}

trace_services_doc="$(curl -s "${VT_URL}/select/jaeger/api/services")"
recent_log_services_doc="$(
  curl -s "${VL_URL}/select/logsql/query" \
    --data-urlencode "query=_time:${lookback} *" \
    --data-urlencode "limit=500" |
    jq -cs '[.[] | ."service.name" // empty | select(. != "")] | unique'
)"
metric_names_doc="$(
  metric_query "count by (__name__) ({service_name=\"${svc_label}\"})" |
    jq -c '[.data.result[]?.metric.__name__] | unique'
)"
orders_doc="$(metric_query "sum by (outcome) (orders_processed_total{service_name=\"${svc_label}\"})")"
error_rate_doc="$(
  metric_query "sum(orders_processed_total{service_name=\"${svc_label}\",outcome=\"error\"}) / clamp_min(sum(orders_processed_total{service_name=\"${svc_label}\"}), 1)"
)"
p95_doc="$(
  metric_query "histogram_quantile(0.95, sum by (le) (increase(order_processing_seconds_bucket{service_name=\"${svc_label}\"}[${lookback}])))"
)"
recent_errors_doc="$(
  "${dir}/app.sh" errors "${svc}" "${lookback}" 10 |
    jq -cs 'map({
      time: ._time,
      message: ._msg,
      url: ."req.url",
      method: ."req.method",
      status: (.statusCode // ."res.statusCode"),
      forced,
      trace_id,
      span_id
    })'
)"
error_traces_doc="$(
  curl -s "${VT_URL}/select/jaeger/api/traces" -G \
    --data-urlencode "service=${svc}" \
    --data-urlencode "limit=${limit}" \
    --data-urlencode "lookback=${lookback}" \
    --data-urlencode "tags={\"error\":\"true\"}"
)"
trace_summary_doc="$(
  printf '%s\n' "${error_traces_doc}" |
    jq -c '
      def root_span: ([.spans[]? | select((.references // []) | length == 0)] | first) // (.spans[0] // {});
      def tag($key): ([.spans[]?.tags[]? | select(.key == $key) | .value] | first);
      [.data[]? as $trace
        | ($trace | root_span) as $root
        | {
            traceID: $trace.traceID,
            service: ($trace.processes[($root.processID // "")].serviceName // null),
            root: ($root.operationName // null),
            durationMs: ((($root.duration // 0) / 1000) * 100 | round / 100),
            status: ($trace | tag("http.status_code")),
            correlate: ("./obs/correlate.sh " + $trace.traceID)
          }
      ]'
)"

orders_present="$(printf '%s\n' "${metric_names_doc}" | jq -r 'index("orders_processed_total") != null')"
latency_present="$(printf '%s\n' "${metric_names_doc}" | jq -r 'index("order_processing_seconds_bucket") != null')"
orders_result="$(printf '%s\n' "${orders_doc}" | jq -c '.data.result // []')"
error_rate_result="$(printf '%s\n' "${error_rate_doc}" | jq -c '.data.result // []')"
p95_result="$(printf '%s\n' "${p95_doc}" | jq -c '.data.result // []')"

if [[ "${json_mode}" -eq 1 ]]; then
  jq -n \
    --arg service "${svc}" \
    --arg lookback "${lookback}" \
    --arg vmui "${VM_URL}/vmui/" \
    --arg vlui "${VL_URL}/select/vmui/" \
    --arg vtui "${VT_URL}/select/jaeger/" \
    --argjson traceServices "$(printf '%s\n' "${trace_services_doc}" | jq -c '.data // []')" \
    --argjson logServices "${recent_log_services_doc}" \
    --argjson metricNames "${metric_names_doc}" \
    --argjson orders "${orders_result}" \
    --argjson errorRate "${error_rate_result}" \
    --argjson p95 "${p95_result}" \
    --argjson recentErrors "${recent_errors_doc}" \
    --argjson errorTraces "${trace_summary_doc}" \
    '{
      service: $service,
      lookback: $lookback,
      services: {
        traces: $traceServices,
        logs_recent: $logServices
      },
      metric_availability: {
        names: $metricNames,
        business: {
          orders_processed_total: ($metricNames | index("orders_processed_total") != null),
          order_processing_seconds_bucket: ($metricNames | index("order_processing_seconds_bucket") != null)
        }
      },
      panels: {
        business_counters: $orders,
        error_rate_source: "current_counter_ratio",
        error_rate: $errorRate,
        p95_latency_seconds: $p95
      },
      recent_errors: $recentErrors,
      recent_error_traces: $errorTraces,
      correlate_suggestions: ($errorTraces | map(.correlate)),
      ui_urls: {
        VictoriaMetrics: $vmui,
        VictoriaLogs: $vlui,
        VictoriaTraces: $vtui
      }
    }'
  exit 0
fi

if [[ "${compact}" -eq 1 ]]; then
  echo "=== ${svc} (${lookback}) ==="
  printf 'metrics: %s names, orders_processed_total=%s, order_processing_seconds_bucket=%s\n' \
    "$(printf '%s\n' "${metric_names_doc}" | jq 'length')" \
    "${orders_present}" \
    "${latency_present}"

  if [[ "${orders_present}" == "true" ]]; then
    printf 'orders: '
    printf '%s\n' "${orders_result}" |
      jq -r 'if length == 0 then "none" else map((.metric.outcome // "unknown") + "=" + .value[1]) | join(" ") end'
  else
    echo "orders: metric unavailable"
  fi

  if [[ "${orders_present}" == "true" ]]; then
    printf 'error_ratio_total: '
    printf '%s\n' "${error_rate_result}" | jq -r '.[0].value[1] // "n/a"'
  else
    echo "error_ratio_total: metric unavailable"
  fi

  if [[ "${latency_present}" == "true" ]]; then
    printf 'p95_latency_seconds: '
    printf '%s\n' "${p95_result}" | jq -r '.[0].value[1] // "n/a"'
  else
    echo "p95_latency_seconds: metric unavailable"
  fi

  printf 'recent_errors: %s\n' "$(printf '%s\n' "${recent_errors_doc}" | jq 'length')"
  echo "recent_error_traces:"
  printf '%s\n' "${trace_summary_doc}" |
    jq -r '.[]? | "- \(.traceID) status=\(.status // "n/a") root=\(.root // "n/a") duration_ms=\(.durationMs) | \(.correlate)"'
  echo "uis: ${VM_URL}/vmui/ ${VL_URL}/select/vmui/ ${VT_URL}/select/jaeger/"
  exit 0
fi

echo "=== OBSERVABILITY OVERVIEW: ${svc} (${lookback}) ==="
echo

echo "== Services =="
echo "Trace services:"
printf '%s\n' "${trace_services_doc}" | jq '.data // []'
echo "Recent log services (${lookback}):"
printf '%s\n' "${recent_log_services_doc}" | jq '.'
echo

echo "== Metric availability =="
printf '%s\n' "${metric_names_doc}" | jq '.'
echo "App-specific panels:"
echo "  orders_processed_total: ${orders_present}"
echo "  order_processing_seconds_bucket: ${latency_present}"
echo

echo "== Business counters =="
if [[ "${orders_present}" == "true" ]]; then
  printf '%s\n' "${orders_result}" | jq '.'
else
  echo "skipped: orders_processed_total is not present for service_name=${svc}"
fi
echo

echo "== Error ratio (current counters) =="
if [[ "${orders_present}" == "true" ]]; then
  printf '%s\n' "${error_rate_result}" | jq '.'
else
  echo "skipped: orders_processed_total is not present for service_name=${svc}"
fi
echo

echo "== p95 latency (${lookback}) =="
if [[ "${latency_present}" == "true" ]]; then
  printf '%s\n' "${p95_result}" | jq '.'
else
  echo "skipped: order_processing_seconds_bucket is not present for service_name=${svc}"
fi
echo

echo "== Recent errors =="
printf '%s\n' "${recent_errors_doc}" |
  jq -r '.[]? | "- \(.time // "n/a") \(.status // "n/a") \(.method // "GET") \(.url // "n/a") \(.message // "n/a") trace_id=\(.trace_id // "n/a")"'
echo

echo "== Recent error traces =="
printf '%s\n' "${trace_summary_doc}" |
  jq -r '.[]? | "- \(.traceID) status=\(.status // "n/a") root=\(.root // "n/a") duration_ms=\(.durationMs)\n  correlate: \(.correlate)"'
echo

echo "Open built-in UIs:"
echo "  VictoriaMetrics: ${VM_URL}/vmui/"
echo "  VictoriaLogs:    ${VL_URL}/select/vmui/"
echo "  VictoriaTraces:  ${VT_URL}/select/jaeger/"
