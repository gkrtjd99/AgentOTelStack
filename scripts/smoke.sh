#!/usr/bin/env bash
# Gateway-only read-path smoke. Pass --write to explicitly generate workload.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
requests=120; write=0
if [[ "${1:-}" == --write ]]; then write=1; shift; fi
requests="${1:-$requests}"; base_url="${2:-http://127.0.0.1:3000}"
source "$ROOT/obs/common.sh"
need(){ command -v "$1" >/dev/null || die "missing required command: $1"; }; need curl; need jq; need docker
wait_for(){ local n=$1 u=$2; shift 2; for _ in {1..60}; do curl -fsS "$@" "$u" >/dev/null 2>&1 && echo "$n: ok" && return; sleep 1; done; die "$n unavailable"; }
run_id="smoke-$(date +%Y%m%d%H%M%S)-$$"
if (( write )); then
  stack_uuid="$(./bin/obs stack-id)"; SMOKE_RUN_ID="$run_id" AGENTOTEL_STACK_UUID="$stack_uuid" docker compose --profile demo up -d --build
  wait_for "sample app" "$base_url/health"
  "$ROOT/workload/run.sh" "$requests" "$base_url"
  curl -s -o /dev/null "$base_url/api/checkout?fail=1" || true
else
  echo "read-only mode (use --write for workload generation)"
fi
wait_for "query gateway" "${GATEWAY_URL:-http://127.0.0.1:17777}/v1/health" -H "Authorization: Bearer ${GATEWAY_QUERY_TOKEN}"
echo '== Gateway services =='; services="$("$ROOT"/obs/services.sh)"; echo "$services" | jq .
echo '== Gateway context =='; context="$("$ROOT"/obs/context.sh sample-app)"; echo "$context" | jq .
echo '== Gateway errors =='; errors="$("$ROOT"/obs/errors.sh sample-app)"; echo "$errors" | jq .
trace_id="$(printf '%s' "$errors" | jq -r '[.. | objects | (.trace_id // .traceID // empty)] | .[0] // empty')"
if [[ -n "$trace_id" && "$trace_id" != null ]]; then
  [[ "$trace_id" =~ ^[0-9a-f]{32}$ ]] || die "invalid trace id from Gateway"
  echo "== Gateway correlate $trace_id =="; "$ROOT/obs/correlate.sh" "$trace_id" | jq .
elif (( write )); then die 'Gateway errors contained no trace_id'; fi
echo 'smoke ok: authenticated Gateway services/context/errors read contracts verified'
