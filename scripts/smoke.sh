#!/usr/bin/env bash
# End-to-end smoke test for the local observability stack.
#
# It starts the demo profile, generates traffic, then verifies that the write
# path and every read helper return real data:
#   app -> collector -> VictoriaLogs / VictoriaMetrics / VictoriaTraces

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

requests="${1:-120}"
base_url="${2:-http://localhost:3000}"

source "${ROOT}/obs/common.sh"

run_id="smoke-$(date +%Y%m%d%H%M%S)-$$"
run_id_label="$(prom_label_value "${run_id}")"
run_id_log="$(log_field_value "${run_id}")"
metric_selector="{service_name=\"sample-app\",smoke_run_id=\"${run_id_label}\"}"
trace_summary="$(mktemp)"

trap 'rm -f "${trace_summary}"' EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

wait_for() {
  local name="$1"
  local url="$2"
  local tries="${3:-60}"

  printf 'waiting for %s' "${name}"
  for _ in $(seq 1 "${tries}"); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      printf ' ok\n'
      return 0
    fi
    printf '.'
    sleep 1
  done
  printf '\n'
  die "${name} did not become ready at ${url}"
}

wait_for_result() {
  local name="$1"
  local jq_filter="$2"
  local tries="$3"
  local delay="$4"
  local result
  shift 4

  printf 'waiting for %s' "${name}" >&2
  for _ in $(seq 1 "${tries}"); do
    result="$("$@")"
    if printf '%s\n' "${result}" | jq -e "${jq_filter}" >/dev/null 2>&1; then
      printf ' ok\n' >&2
      printf '%s\n' "${result}"
      return 0
    fi
    printf '.' >&2
    sleep "${delay}"
  done
  printf '\n' >&2
  printf '%s\n' "${result:-}"
  die "${name} did not return expected data"
}

need curl
need docker
need jq

echo "== start demo stack =="
SMOKE_RUN_ID="${run_id}" docker compose --profile demo up -d --build
echo "smoke run_id=${run_id}"

wait_for "sample app" "${base_url}/health"
wait_for "VictoriaLogs" "${VL_URL}/health"
wait_for "VictoriaMetrics" "${VM_URL}/health"
wait_for "VictoriaTraces" "${VT_URL}/health"

echo
echo "== generate workload =="
"${ROOT}/workload/run.sh" "${requests}" "${base_url}"
curl -s -o /dev/null -w "%{http_code} /api/checkout?fail=1 smoke-forced\n" \
  "${base_url}/api/checkout?fail=1" || true

echo
echo "== wait for telemetry export =="

echo
echo "== metrics: orders by outcome =="
metrics_json="$(wait_for_result \
  "orders_processed_total for ${run_id}" \
  '.status == "success" and (.data.result | length > 0)' \
  45 \
  2 \
  curl -fsS "${VM_URL}/api/v1/query" \
    --data-urlencode "query=sum by (outcome) (orders_processed_total${metric_selector})")"
echo "${metrics_json}" | jq '.data.result'

echo
echo "== traces: services =="
services_json="$(wait_for_result \
  "sample-app trace service" \
  '.data | index("sample-app")' \
  45 \
  2 \
  curl -fsS "${VT_URL}/select/jaeger/api/services")"
echo "${services_json}" | jq '.data'

echo
echo
echo "== logs: recent errors =="
logs="$(wait_for_result \
  "error logs with trace_id for ${run_id}" \
  'select(.trace_id != null)' \
  45 \
  2 \
  curl -fsS "${VL_URL}/select/logsql/query" \
    --data-urlencode "query=_time:10m smoke.run_id:${run_id_log} severity_text:error" \
    --data-urlencode 'limit=5')"
printf '%s\n' "${logs}"
trace_id="$(printf '%s\n' "${logs}" | jq -r 'select(.trace_id != null) | .trace_id' | head -n 1)"
[[ -n "${trace_id}" && "${trace_id}" != "null" ]] || die "error log search returned no trace_id"

echo
echo "== traces: get fresh error trace =="
echo "selected trace_id=${trace_id}"
trace_get_json="$(wait_for_result \
  "trace get ${trace_id}" \
  '.data | length > 0' \
  45 \
  2 \
  curl -fsS "${VT_URL}/select/jaeger/api/traces/${trace_id}")"
echo "${trace_get_json}" | jq --arg run_id "${run_id}" '
  .data[0]
  | {
      traceID,
      spanCount: (.spans | length),
      service: (.processes[.spans[0].processID].serviceName // null),
      smokeRunId: ([.processes[].tags[] | select(.key == "smoke.run_id")][0].value // null)
    }
  | select(.smokeRunId == $run_id)
' > "${trace_summary}"
[[ -s "${trace_summary}" ]] || die "trace did not carry expected smoke.run_id=${run_id}"
cat "${trace_summary}"

echo
echo "== correlate one failing trace =="
"${ROOT}/obs/correlate.sh" "${trace_id}" 10m

echo
echo "smoke ok: metrics, logs, traces, and correlation all returned data"
