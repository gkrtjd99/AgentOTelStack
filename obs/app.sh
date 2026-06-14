#!/usr/bin/env bash
# Multi-app query helper. Use service.name / service_name consistently across
# logs, metrics, and traces without remembering each backend's syntax.
#
# Usage:
#   obs/app.sh services
#   obs/app.sh summary <service> [lookback]
#   obs/app.sh logs <service> [lookback] [limit]
#   obs/app.sh errors <service> [lookback] [limit]
#   obs/app.sh traces <service> [limit] [lookback]
#   obs/app.sh error-traces <service> [limit] [lookback]
#   obs/app.sh operations <service>
#   obs/app.sh metrics <service>

source "$(dirname "$0")/common.sh"

cmd="${1:?usage: app.sh services|summary|logs|errors|traces|error-traces|operations|metrics ...}"

metric_query() {
  curl -s "${VM_URL}/api/v1/query" --data-urlencode "query=$1" | pp '.data.result'
}

case "${cmd}" in
  services)
    echo "=== TRACE SERVICES ==="
    curl -s "${VT_URL}/select/jaeger/api/services" | pp '.data'
    echo
    echo "=== RECENT LOG SERVICES (last 15m) ==="
    curl -s "${VL_URL}/select/logsql/query" \
      --data-urlencode "query=_time:15m *" \
      --data-urlencode "limit=200" |
      if command -v jq >/dev/null 2>&1; then
        jq -r '."service.name" // empty' | sort -u | jq -R . | jq -s .
      else
        cat
      fi
    ;;
  summary)
    svc="${2:?usage: app.sh summary <service> [lookback]}"
    lookback="$(duration_value "${3:-15m}")"
    "$0" operations "${svc}"
    echo
    "$0" errors "${svc}" "${lookback}" 10
    echo
    "$0" metrics "${svc}"
    ;;
  logs)
    svc="${2:?usage: app.sh logs <service> [lookback] [limit]}"
    lookback="$(duration_value "${3:-15m}")"
    limit="$(limit_value "${4:-50}")"
    log_svc="$(log_field_value "${svc}")"
    curl -s "${VL_URL}/select/logsql/query" \
      --data-urlencode "query=_time:${lookback} service.name:${log_svc}" \
      --data-urlencode "limit=${limit}"
    ;;
  errors)
    svc="${2:?usage: app.sh errors <service> [lookback] [limit]}"
    lookback="$(duration_value "${3:-15m}")"
    limit="$(limit_value "${4:-20}")"
    log_svc="$(log_field_value "${svc}")"
    curl -s "${VL_URL}/select/logsql/query" \
      --data-urlencode "query=_time:${lookback} service.name:${log_svc} severity_text:error" \
      --data-urlencode "limit=${limit}"
    ;;
  traces)
    svc="${2:?usage: app.sh traces <service> [limit] [lookback]}"
    limit="$(limit_value "${3:-20}")"
    lookback="$(duration_value "${4:-1h}")"
    "$(dirname "$0")/traces.sh" search "${svc}" "${limit}" "${lookback}"
    ;;
  error-traces)
    svc="${2:?usage: app.sh error-traces <service> [limit] [lookback]}"
    limit="$(limit_value "${3:-20}")"
    lookback="$(duration_value "${4:-1h}")"
    "$(dirname "$0")/traces.sh" search-errors "${svc}" "${limit}" "${lookback}"
    ;;
  operations)
    svc="${2:?usage: app.sh operations <service>}"
    "$(dirname "$0")/traces.sh" operations "${svc}"
    ;;
  metrics)
    svc="${2:?usage: app.sh metrics <service>}"
    svc_label="$(prom_label_value "${svc}")"
    echo "=== METRIC NAMES with service_name=${svc} ==="
    metric_query "count by (__name__) ({service_name=\"${svc_label}\"})"
    echo
    echo "=== orders_processed_total by outcome, if present ==="
    metric_query "sum by (outcome) (orders_processed_total{service_name=\"${svc_label}\"})"
    echo
    echo "=== order_processing_seconds p95, if present ==="
    metric_query "histogram_quantile(0.95, sum by (le) (increase(order_processing_seconds_bucket{service_name=\"${svc_label}\"}[15m])))"
    ;;
  *)
    die "unknown subcommand: ${cmd}"
    ;;
esac
