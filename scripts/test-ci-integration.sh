#!/usr/bin/env bash
# CI-only live integration test. Every resource is scoped by project, UUID, and
# loopback-only dynamically selected host ports.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
  project="$COMPOSE_PROJECT_NAME"
else
  project="agentotel-ci-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$"
fi
uuid="${AGENTOTEL_STACK_UUID:-}"
if [[ -z "$uuid" ]]; then
  uuid="$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-4\3-8\4-\5/')"
fi
uuid="$(printf '%s' "$uuid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { echo "FAIL: invalid AGENTOTEL_STACK_UUID scope '$uuid'" >&2; exit 2; }
project_uuid="${AGENTOTEL_PROJECT_ID:-}"
if [[ -z "$project_uuid" ]]; then project_uuid="$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-4\3-8\4-\5/')"; fi
project_uuid="$(printf '%s' "$project_uuid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$project_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { echo "FAIL: invalid AGENTOTEL_PROJECT_ID '$project_uuid'" >&2; exit 2; }
[[ "$project_uuid" != "$uuid" ]] || { echo 'FAIL: project UUID must differ from stack UUID' >&2; exit 2; }
export COMPOSE_PROJECT_NAME="$project" AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project_uuid"
printf 'run scope uuid=%s\n' "$uuid"
printf 'telemetry project id=%s\n' "$project_uuid"
pick_port() {
  local value="$1" name="$2"
  if [[ -n "$value" ]]; then
    if ! [[ "$value" =~ ^[0-9]+$ ]] || ! (( value >= 1024 && value <= 65535 )); then echo "FAIL: $name must be a TCP port (1024-65535), got '$value'" >&2; exit 2; fi
    python3 - "$value" <<'PY' || { echo "FAIL: $name=$value is unavailable on loopback" >&2; exit 2; }
import socket, sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError: sys.exit(1)
finally: s.close()
PY
    printf '%s' "$value"; return
  fi
  python3 <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}
GATEWAY_INGEST_HOST_PORT="$(pick_port "${GATEWAY_INGEST_HOST_PORT:-}" GATEWAY_INGEST_HOST_PORT)"; export GATEWAY_INGEST_HOST_PORT
GATEWAY_QUERY_HOST_PORT="$(pick_port "${GATEWAY_QUERY_HOST_PORT:-}" GATEWAY_QUERY_HOST_PORT)"; export GATEWAY_QUERY_HOST_PORT
APP_HOST_PORT="$(pick_port "${APP_HOST_PORT:-}" APP_HOST_PORT)"; export APP_HOST_PORT
GRAFANA_HOST_PORT="$(pick_port "${GRAFANA_HOST_PORT:-}" GRAFANA_HOST_PORT)"; export GRAFANA_HOST_PORT
export GATEWAY_URL="http://127.0.0.1:${GATEWAY_QUERY_HOST_PORT}"
export APP_URL="http://127.0.0.1:${APP_HOST_PORT}"
ci_ready_timeout="${CI_READY_POLL_SECONDS:-90}"
# Keep the CI names distinct from local shell variables (and do not assign to a
# possibly readonly inherited variable).  Compose and every obs helper consume
# these exact exported values.
normalize_token() {
  local token="$1"
  printf '%s' "$token" | tr -d '[:space:]'
}
ci_ingest_token="$(normalize_token "${GATEWAY_INGEST_TOKEN:-ci-ingest-${uuid}}")"
ci_query_token="$(normalize_token "${GATEWAY_QUERY_TOKEN:-ci-query-${uuid}}")"
export GATEWAY_INGEST_TOKEN="$ci_ingest_token" GATEWAY_QUERY_TOKEN="$ci_query_token"
export GF_SECURITY_ADMIN_PASSWORD="${GF_SECURITY_ADMIN_PASSWORD:-ci-grafana-${uuid}}"
# Fingerprints are deliberately computed from the token bytes at each boundary;
# hashing the whole Compose document or environment can hide a missing/wrong
# value.  Never print the value or a bearer header.
token_fingerprint() {
  if (( $# != 1 )); then
    echo 'FAIL: token_fingerprint requires exactly one argument' >&2
    return 2
  fi
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}
if [[ "$(token_fingerprint 'ci-fingerprint-self-test')" != ced3d3dcbf25c5ed0ca9568e1fab3f9ccc8f3c1cba3cac333665cb1c205582b8 ]]; then
  echo 'FAIL: token_fingerprint self-test failed' >&2
  exit 2
fi
script_query_fp="$(token_fingerprint "$ci_query_token")"
volumes=("${project}_otelcol-queue" "${project}_victorialogs-data" "${project}_victoriametrics-data" "${project}_victoriatraces-data" "${project}_grafana-data")
cleanup() {
  set +e
  if [[ "${ci_failed:-0}" == 1 ]]; then
    echo '== CI failure diagnostics (safe metadata/log tail) ==' >&2
    docker compose ps >&2 || true
    docker compose images >&2 || true
    docker compose logs --no-color --tail=80 gateway otel-collector victorialogs victoriametrics victoriatraces >&2 || true
  fi
  docker compose --profile demo --profile dashboard down --remove-orphans >/dev/null 2>&1
  # External volumes are deliberately removed only by their exact generated names.
  for v in "${volumes[@]}"; do docker volume rm "$v" >/dev/null 2>&1 || true; done
}
ci_failed=1
trap cleanup EXIT

make setup
if ! docker compose --profile demo up -d --build --force-recreate; then
  echo "FAIL: isolated stack could not bind selected loopback ports (app=$APP_HOST_PORT ingest=$GATEWAY_INGEST_HOST_PORT query=$GATEWAY_QUERY_HOST_PORT grafana=$GRAFANA_HOST_PORT); retry to avoid a bind race" >&2
  exit 1
fi
gateway_port_mapping="$(docker compose port gateway 17777 2>&1 || true)"
printf 'gateway query port mapping: expected=127.0.0.1:%s actual=%s url=%s\n' \
  "$GATEWAY_QUERY_HOST_PORT" "$gateway_port_mapping" "$GATEWAY_URL"
[[ "$gateway_port_mapping" == *":${GATEWAY_QUERY_HOST_PORT}" ]] || {
  echo 'FAIL: gateway query port mapping does not match selected host port' >&2
  exit 1
}
for _ in $(seq 1 "$ci_ready_timeout"); do curl -fsS "$APP_URL/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$APP_URL/health" >/dev/null

# A stale gateway can be healthy while still holding yesterday's token.  Read
# only the exact query-token value at every boundary (never print secrets).
rendered_query_token="$(docker compose config --format json | jq -er '.services.gateway.environment.GATEWAY_QUERY_TOKEN')"
rendered_query_fp="$(token_fingerprint "$rendered_query_token")"
container_query_token="$(docker inspect "${COMPOSE_PROJECT_NAME}-gateway-1" -f '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1 == "GATEWAY_QUERY_TOKEN" {sub(/^[^=]*=/, ""); print; exit}')"
container_query_fp="$(token_fingerprint "$container_query_token")"
curl_bearer_payload="Bearer ${ci_query_token}"
wrong_bearer_payload="Bearer ci-definitely-wrong-token"
auth_probe() {
  local bearer="$1" endpoint="$2"
  curl --connect-timeout 2 --max-time 5 -sS -o /dev/null -w '%{http_code}' \
    --header "$(printf 'Authorization: %s' "$bearer")" "$endpoint" || true
}
auth_probe_to_file() {
  local bearer="$1" endpoint="$2" output="$3"
  curl --connect-timeout 2 --max-time 5 -sS -o "$output" -w '%{http_code}' \
    --header "$(printf 'Authorization: %s' "$bearer")" "$endpoint" || true
}
curl_query_fp="$(token_fingerprint "${curl_bearer_payload#Bearer }")"
printf 'gateway query-token fingerprints: script-env=%s rendered-compose=%s container-env=%s curl-bearer=%s\n' \
  "$script_query_fp" "$rendered_query_fp" "$container_query_fp" "$curl_query_fp"
[[ "$script_query_fp" == "$rendered_query_fp" && "$script_query_fp" == "$container_query_fp" && "$script_query_fp" == "$curl_query_fp" ]] || {
  echo 'FAIL: query token changed across script, Compose, container, or curl boundaries' >&2
  exit 1
}
# First prove the query listener itself is live and authenticates independently
# of backend warmup. Then wait separately for the traces-backed services query.
for _ in $(seq 1 "$ci_ready_timeout"); do
  wrong_health_status="$(auth_probe "$wrong_bearer_payload" "$GATEWAY_URL/v1/health")"
  right_health_status="$(auth_probe "$curl_bearer_payload" "$GATEWAY_URL/v1/health")"
  [[ "$wrong_health_status" == 401 && "$right_health_status" == 200 ]] && break
  sleep 1
done
if [[ "$wrong_health_status" != 401 || "$right_health_status" != 200 ]]; then
  echo "FAIL: query health did not authenticate with the current query token (wrong_http=$wrong_health_status right_http=$right_health_status)" >&2
  diag_body="$(mktemp "${TMPDIR:-/tmp}/agentotel-ci-auth.XXXXXX")"
  wrong_probe="$(auth_probe_to_file "$wrong_bearer_payload" "$GATEWAY_URL/v1/health" "$diag_body")"
  right_probe="$(auth_probe_to_file "$curl_bearer_payload" "$GATEWAY_URL/v1/health" "$diag_body")"
  printf 'auth probe: expected=127.0.0.1:%s actual=%s wrong_http=%s right_http=%s\n' \
    "$GATEWAY_QUERY_HOST_PORT" "$gateway_port_mapping" "$wrong_probe" "$right_probe" >&2
  echo 'auth probe response body (safe, truncated):' >&2; head -c 512 "$diag_body" >&2 || true; echo >&2
  rm -f "$diag_body"
  echo 'gateway image/container source:' >&2
  docker inspect "${COMPOSE_PROJECT_NAME}-gateway-1" -f 'image_id={{.Image}} config_image={{.Config.Image}}' >&2 || true
  docker compose logs --no-color --since 2m gateway >&2 || true
  exit 1
fi
services_status=000
for _ in $(seq 1 "$ci_ready_timeout"); do
  services_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: $curl_bearer_payload" "$GATEWAY_URL/v1/services" || true)"
  printf 'query services readiness status=%s\n' "$services_status"
  [[ "$services_status" == 200 ]] && break
  [[ "$services_status" == 502 || "$services_status" == 503 || "$services_status" == 000 ]] || { echo "FAIL: unexpected query services status=$services_status" >&2; exit 1; }
  sleep 1
done
[[ "$services_status" == 200 ]] || { echo 'FAIL: query services did not become ready before timeout' >&2; exit 1; }

./workload/run.sh "${CI_WORKLOAD_REQUESTS:-40}" "$APP_URL"
# The workload above plus the forced request below cover the live write path;
# keep the smoke helper out of this isolated run because it is a separate
# stack lifecycle/read-contract test and can race another local invocation.
# Force a uniquely scoped failure after readiness. Collector batching and
# backend indexing are asynchronous, so poll the isolated project/window.
curl -sS --max-time 15 -o /dev/null "$APP_URL/api/checkout?fail=1" || true
trace=''; correlation=''; last_correlation_summary='{}'
for _ in $(seq 1 "${CI_ERROR_POLL_SECONDS:-60}"); do
  errors_response="$(curl -sS -w $'\n__HTTP_STATUS__%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get "$GATEWAY_URL/v1/errors" \
    --data-urlencode 'service=sample-app' --data-urlencode "project=$project_uuid" --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || true)"
  errors_status="${errors_response##*__HTTP_STATUS__}"
  errors="${errors_response%$'\n__HTTP_STATUS__'*}"
  if [[ "$errors_status" != 200 && "${errors_status_reported:-0}" != 1 ]]; then
    printf 'error query status=%s scope=%s\n' "$errors_status" "$project_uuid" >&2
    errors_status_reported=1
  fi
  # Only consider a trace when the same response contains an explicit error
  # log carrying that trace_id and a stored trace record.  This avoids picking
  # a successful/flaky trace while the forced failure is still being indexed.
  candidates="$(printf '%s' "$errors" | jq -r '
    def tid: (.trace_id // .traceID // empty);
    [.. | objects | select((.severity_text // .severityText // "" | ascii_downcase) == "error")
      | tid | select(type == "string" and test("^[0-9a-f]{32}$"))] | unique[]' 2>/dev/null || true)"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    has_stored_trace="$(printf '%s' "$errors" | jq -e --arg t "$candidate" '[.. | objects | select((.trace_id // .traceID // empty) == $t and ((.spans? // []) | length > 0))] | length > 0' >/dev/null 2>&1; echo "$?")"
    [[ "$has_stored_trace" == 0 ]] || continue
    candidate_correlation="$(curl -sS --max-time 15 -X POST -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" -H 'Content-Type: application/json' --data "{\"trace_id\":\"$candidate\"}" "$GATEWAY_URL/v1/correlate" || true)"
    last_correlation_summary="$(printf '%s' "$candidate_correlation" | jq -c '{schema_version,partial,backends:([.backends[]? | {name,status}]),warnings:(.warnings // [])}' 2>/dev/null || printf '%s' '{"decode":"invalid"}')"
    if printf '%s' "$candidate_correlation" | jq -e '.schema_version=="1.0" and .partial==false and ([.backends[]?.status] | length >= 3 and all(. == "ok")) and ((.data.correlation.spans // []) | length > 0) and (.data.correlation.logs != null) and (.data.correlation.metrics != null)' >/dev/null 2>&1; then
      trace="$candidate"; correlation="$candidate_correlation"; break 2
    fi
  done <<< "$candidates"
  [[ -n "$trace" ]] && break
  sleep 1
done
if ! test -n "$trace" || ! [[ "$trace" =~ ^[0-9a-f]{32}$ ]]; then
  printf 'FAIL: no fully correlated forced-error trace after bounded poll; last=%s\n' "$last_correlation_summary" >&2
  exit 1
fi
curl -fsS -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" "$GATEWAY_URL/v1/version" | jq -e '.schema_version=="1.0" and .api_min=="1.0" and .api_max=="1.0"'
printf '%s' "$correlation" | jq -e '.schema_version=="1.0" and .partial==false and ([.backends[]?.status] | length>=3 and all(. == "ok"))'

# Prove the partial-backend contract with a controlled, reversible outage.
docker compose stop victorialogs
outage_response="$(curl -fsS -w $'\n__HTTP_STATUS__%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get "$GATEWAY_URL/v1/errors" \
  --data-urlencode 'service=sample-app' --data-urlencode "project=$project_uuid" --data-urlencode 'lookback=5m' --data-urlencode 'limit=100')"
outage_status="${outage_response##*__HTTP_STATUS__}"
outage_body="${outage_response%$'\n__HTTP_STATUS__'*}"
[[ "$outage_status" == 200 ]] || { echo "FAIL: VictoriaLogs outage context status=$outage_status" >&2; exit 1; }
# A partial response must identify the unavailable logs backend while retaining
# at least one healthy peer.  In particular, no_data is not an outage signal.
printf '%s' "$outage_body" | jq -e '
  .schema_version == "1.0" and .partial == true and
  ([.backends[]? | select(.name == "logs" and (.status == "backend_unavailable" or .status == "timeout"))] | length == 1) and
  ([.backends[]? | select(.name != "logs" and .status == "ok")] | length >= 1) and
  ([.backends[]? | select(.name == "logs" and (.status == "no_data" or .status == "no_matching" or .status == "no_matching_data"))] | length == 0)
'
docker compose start victorialogs
# Confirm the backend is healthy again and that the same scoped endpoint has
# returned to a complete envelope (not merely an HTTP-successful no-data one).
recovered=0
for _ in $(seq 1 "$ci_ready_timeout"); do
  health_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" "$GATEWAY_URL/v1/health" || true)"
  recovery_response="$(curl -sS -w $'\n__HTTP_STATUS__%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get "$GATEWAY_URL/v1/errors" \
    --data-urlencode 'service=sample-app' --data-urlencode "project=$project_uuid" --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || true)"
  recovery_status="${recovery_response##*__HTTP_STATUS__}"
  recovery_body="${recovery_response%$'\n__HTTP_STATUS__'*}"
  if [[ "$health_status" == 200 && "$recovery_status" == 200 ]] && printf '%s' "$recovery_body" | jq -e '
    .schema_version == "1.0" and .partial == false and
    ([.backends[]? | select(.name == "logs" and .status == "ok")] | length == 1) and
    ([.backends[]? | select(.status != "ok")] | length == 0)
  ' >/dev/null 2>&1; then
    recovered=1
    break
  fi
  sleep 1
done
[[ "$recovered" == 1 ]] || { echo "FAIL: VictoriaLogs did not recover (health=$health_status context_http=$recovery_status)" >&2; exit 1; }
ci_failed=0
echo "PASS live integration project=$project stack_uuid=$uuid telemetry_project=$project_uuid ports=app:$APP_HOST_PORT ingest:$GATEWAY_INGEST_HOST_PORT query:$GATEWAY_QUERY_HOST_PORT trace=$trace"
