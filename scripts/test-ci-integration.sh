#!/usr/bin/env bash
# CI-only live integration test. Every resource is scoped by project, UUID, and
# loopback-only dynamically selected host ports.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
normalize_component() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g'
}
ci_run_component="$(normalize_component "${GITHUB_RUN_ID:-local}")"; [[ -n "$ci_run_component" ]] || ci_run_component=local
ci_attempt_component="$(normalize_component "${GITHUB_RUN_ATTEMPT:-0}")"; [[ -n "$ci_attempt_component" ]] || ci_attempt_component=0
# Never honor a caller's COMPOSE_PROJECT_NAME. This generated name is both
# CI-specific and unique for the invocation, so a cleanup failure cannot target
# an unrelated local project.
project="agentotel-ci-${ci_run_component}-${ci_attempt_component}-$(date +%s)-$$"
project="${project:0:63}"
project="${project%-}"
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || { echo "FAIL: invalid generated Compose project '$project'" >&2; exit 2; }

uuid="${AGENTOTEL_STACK_UUID:-}"
if [[ -z "$uuid" ]]; then
  uuid="$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-4\3-8\4-\5/')"
fi
uuid="$(printf '%s' "$uuid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
# Stack UUIDs preserve their existing broad RFC version contract; the telemetry
# project UUID has the stricter UUIDv4 contract below.
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { echo "FAIL: invalid AGENTOTEL_STACK_UUID scope '$uuid'" >&2; exit 2; }
project_uuid="${AGENTOTEL_PROJECT_ID:-}"
if [[ -z "$project_uuid" ]]; then project_uuid="$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-4\3-8\4-\5/')"; fi
project_uuid="$(printf '%s' "$project_uuid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$project_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { echo "FAIL: AGENTOTEL_PROJECT_ID must be UUIDv4, got '$project_uuid'" >&2; exit 2; }
[[ "$project_uuid" != "$uuid" ]] || { echo 'FAIL: project UUID must differ from stack UUID' >&2; exit 2; }
export AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project_uuid"
printf 'run scope project=%s stack_uuid=%s\n' "$project" "$uuid"
printf 'telemetry project id=%s\n' "$project_uuid"

# Every Compose call in this integration uses one absolute file and one
# generated project. The hostile inherited selectors and caller project are
# removed before entering the checkout wrapper.
compose() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 \
    "$ROOT/scripts/make-compose.sh" --project "$project" --project-id "$project_uuid" compose "$@"
}
compose_setup() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 COMPOSE_PROJECT_NAME="$project" \
    "$ROOT/bin/obs" setup
}
compose_raw() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    COMPOSE_PROJECT_NAME="$project" \
    docker compose -f "$ROOT/docker-compose.yml" -p "$project" "$@"
}

requested_gateway_ingest_port="${GATEWAY_INGEST_HOST_PORT:-}"
requested_gateway_query_port="${GATEWAY_QUERY_HOST_PORT:-}"
requested_app_port="${APP_HOST_PORT:-}"
requested_dashboard_port="${DASHBOARD_HOST_PORT:-}"
. "$ROOT/scripts/port-selection.sh"
# Automatic ports are a preflight selection only: the socket closes before
# Compose binds it, so Docker remains authoritative. Automatic selections are
# retried after a bind failure; explicit selections are never changed. The
# residual preflight-to-bind race is intentional and bounded.
port_selection_select || exit $?
ci_ready_timeout="${CI_READY_POLL_SECONDS:-90}"
# Keep the CI names distinct from local shell variables (and do not assign to a
# possibly readonly inherited variable).  Compose and every obs helper consume
# these exact exported values.
normalize_token() {
  local token="$1"
  printf '%s' "$token" | tr -d '[:space:]'
}
generate_dashboard_token() {
  local token
  for _ in 1 2 3; do
    token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$token" =~ ^[0-9a-f]{64}$ && "$token" != "$ci_query_token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  done
  echo 'FAIL: unable to generate a distinct dashboard client token' >&2
  exit 2
}
ci_ingest_token="$(normalize_token "${GATEWAY_INGEST_TOKEN:-ci-ingest-${uuid}}")"
ci_query_token="$(normalize_token "${GATEWAY_QUERY_TOKEN:-ci-query-${uuid}}")"
ci_dashboard_client_token="$(generate_dashboard_token)"
export GATEWAY_INGEST_TOKEN="$ci_ingest_token" GATEWAY_QUERY_TOKEN="$ci_query_token" \
  DASHBOARD_CLIENT_TOKEN="$ci_dashboard_client_token"
# Exact response trace IDs are enabled only for this controlled integration;
# the Compose default remains disabled for ordinary app traffic.
export AGENTOTEL_EXPOSE_TRACE_ID_HEADER=1
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
# setup persists the stack UUID and deliberately rejects an override that does
# not match an existing identity. Keep this CI proof hermetic so the requested
# UUID is the bootstrap identity rather than inheriting a developer's state.
ci_xdg_root="$(mktemp -d "${TMPDIR:-/tmp}/agentotel-ci-state.XXXXXX")"
export XDG_CONFIG_HOME="$ci_xdg_root/config" XDG_DATA_HOME="$ci_xdg_root/data" XDG_STATE_HOME="$ci_xdg_root/state" XDG_RUNTIME_DIR="$ci_xdg_root/runtime"
volumes=("${project}_otelcol-queue" "${project}_victorialogs-data" "${project}_victoriametrics-data" "${project}_victoriatraces-data")
networks=("${project}_default" "${project}_edge" "${project}_backend" "${project}_dashboard")
setup_attempted=0
compose_attempted=0
trap 'rm -rf "$ci_xdg_root"' EXIT

. "$ROOT/scripts/ci-resource-guard.sh"

ci_resource_inventory_preflight || exit 1
ci_failed=1
trap ci_resource_cleanup EXIT

setup_attempted=1
compose_setup >/dev/null
# Verify setup created only the exact, correctly labeled external volumes.
for volume in "${volumes[@]}"; do
  ci_resource_exact_volume_labels "$volume" || { echo "FAIL: setup did not create correctly labeled volume $volume" >&2; exit 1; }
done
compose_attempt=1
compose_attempted=1
while :; do
  if compose --profile demo --profile dashboard up -d --build --force-recreate; then
    break
  fi
  if (( auto_port_count == 0 || compose_attempt >= 3 )); then
    echo "FAIL: Compose could not start after $compose_attempt attempt(s); explicit host ports were not changed (app=$APP_HOST_PORT ingest=$GATEWAY_INGEST_HOST_PORT query=$GATEWAY_QUERY_HOST_PORT dashboard=$DASHBOARD_HOST_PORT)" >&2
    exit 1
  fi
  echo "WARN: Compose startup failed on attempt $compose_attempt; retrying with newly selected automatic ports (explicit ports unchanged)" >&2
  if ! compose --profile demo --profile dashboard down --remove-orphans >/dev/null; then
    echo 'FAIL: Compose down failed while retrying automatic ports' >&2
    exit 1
  fi
  compose_attempt=$((compose_attempt + 1))
  port_selection_select
  printf 'retry port selection: app=%s ingest=%s query=%s dashboard=%s\n' \
    "$APP_HOST_PORT" "$GATEWAY_INGEST_HOST_PORT" "$GATEWAY_QUERY_HOST_PORT" "$DASHBOARD_HOST_PORT"
done
gateway_port_mapping="$(compose port gateway 17777 2>&1 || true)"
printf 'gateway query port mapping: expected=127.0.0.1:%s actual=%s url=%s\n' \
  "$GATEWAY_QUERY_HOST_PORT" "$gateway_port_mapping" "$GATEWAY_URL"
[[ "$gateway_port_mapping" == *":${GATEWAY_QUERY_HOST_PORT}" ]] || {
  echo 'FAIL: gateway query port mapping does not match selected host port' >&2
  exit 1
}
dashboard_port_mapping="$(compose port dashboard 3000 2>&1 || true)"
printf 'dashboard port mapping: expected=127.0.0.1:%s actual=%s url=%s\n' \
  "$DASHBOARD_HOST_PORT" "$dashboard_port_mapping" "$DASHBOARD_URL"
[[ "$dashboard_port_mapping" == *":${DASHBOARD_HOST_PORT}" ]] || {
  echo 'FAIL: dashboard port mapping does not match selected host port' >&2
  exit 1
}
for _ in $(seq 1 "$ci_ready_timeout"); do curl -fsS "$APP_URL/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$APP_URL/health" >/dev/null
# /health deliberately permits only in-container loopback callers. The
# dashboard helper proves process health, same-origin proxying, and the
# Gateway-backed query contract in one bounded API readiness loop.
DASHBOARD_URL="$DASHBOARD_URL" DASHBOARD_READY_TIMEOUT="$ci_ready_timeout" "$ROOT/scripts/dashboard-readiness.sh"

# A stale gateway can be healthy while still holding yesterday's token.  Read
# only the exact query-token value at every boundary (never print secrets).
rendered_query_token="$(compose_raw config --format json | jq -er '.services.gateway.environment.GATEWAY_QUERY_TOKEN')"
rendered_query_fp="$(token_fingerprint "$rendered_query_token")"
container_query_token="$(docker inspect "${project}-gateway-1" -f '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1 == "GATEWAY_QUERY_TOKEN" {sub(/^[^=]*=/, ""); print; exit}')"
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
  docker inspect "${project}-gateway-1" -f 'image_id={{.Image}} config_image={{.Config.Image}}' >&2 || true
  compose logs --no-color --since 2m gateway >&2 || true
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

# Dashboard is a same-origin, read-only adapter.  Exercise its public
# surface without sending a browser credential, and prove that it cannot be
# retargeted to another project or expose backend listener ports.
dashboard_root="$(curl -fsS "$DASHBOARD_URL/")"
printf '%s' "$dashboard_root" | grep -Fq 'Observability Console' || {
  echo 'FAIL: dashboard root did not serve the embedded console' >&2
  exit 1
}
for forged_header in \
  '' \
  'Dashboard 0000000000000000000000000000000000000000000000000000000000000000' \
  "Bearer $GATEWAY_QUERY_TOKEN" \
  "Bearer $GATEWAY_INGEST_TOKEN"; do
  forged_body="$(mktemp "${TMPDIR:-/tmp}/agentotel-dashboard-auth.XXXXXX")"
  if [[ -n "$forged_header" ]]; then
    forged_status="$(curl -sS -o "$forged_body" -w '%{http_code}' -H "Authorization: $forged_header" "$DASHBOARD_URL/api/services" || true)"
  else
    forged_status="$(curl -sS -o "$forged_body" -w '%{http_code}' "$DASHBOARD_URL/api/services" || true)"
  fi
  [[ "$forged_status" == 401 ]] || {
    echo "FAIL: forged or missing Dashboard authorization was accepted (http=$forged_status)" >&2
    rm -f "$forged_body"
    exit 1
  }
  grep -Fq '"error":"unauthorized"' "$forged_body" || {
    echo 'FAIL: unauthorized Dashboard response was not generic' >&2
    rm -f "$forged_body"
    exit 1
  }
  ! grep -Fq -- "$DASHBOARD_CLIENT_TOKEN" "$forged_body" || {
    echo 'FAIL: unauthorized Dashboard response echoed the client token' >&2
    rm -f "$forged_body"
    exit 1
  }
  rm -f "$forged_body"
done
dashboard_services="$(curl -fsS -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" "$DASHBOARD_URL/api/services")"
printf '%s' "$dashboard_services" | jq -e '.schema_version == "dashboard.v1" and .kind == "services" and .scope.project_bound == true' >/dev/null || {
  echo 'FAIL: dashboard services response is not a bounded dashboard envelope' >&2
  exit 1
}
for endpoint_body in "$dashboard_root" "$(curl -fsS "$DASHBOARD_URL/assets/app.js")" "$dashboard_services"; do
  ! printf '%s' "$endpoint_body" | grep -Fq -- "$GATEWAY_QUERY_TOKEN" || {
    echo 'FAIL: dashboard response leaked the Gateway query credential' >&2
    exit 1
  }
done
override_body="$(mktemp "${TMPDIR:-/tmp}/agentotel-dashboard-override.XXXXXX")"
override_status="$(curl -sS -o "$override_body" -w '%{http_code}' -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" "$DASHBOARD_URL/api/services?project=$uuid" || true)"
[[ "$override_status" == 400 ]] || {
  echo "FAIL: dashboard project override was accepted (http=$override_status)" >&2
  rm -f "$override_body"
  exit 1
}
! grep -Fq -- "$GATEWAY_QUERY_TOKEN" "$override_body" || {
  echo 'FAIL: dashboard project-override error leaked the Gateway query credential' >&2
  rm -f "$override_body"
  exit 1
}
rm -f "$override_body"
for backend_port in 9428 8428 10428; do
  case "$backend_port" in
    9428) backend_service=victorialogs ;;
    8428) backend_service=victoriametrics ;;
    10428) backend_service=victoriatraces ;;
  esac
  backend_mapping="$(compose port "$backend_service" "$backend_port" 2>/dev/null || true)"
  # Compose emits `invalid IP:0` for a service port with no host binding on
  # current Docker Compose versions; treat that sentinel as unpublished.
  [[ -z "$backend_mapping" || "$backend_mapping" == 'invalid IP:0' ]] || {
    echo "FAIL: backend $backend_service:$backend_port is published as $backend_mapping" >&2
    exit 1
  }
done

env -u DASHBOARD_CLIENT_TOKEN ./workload/run.sh "${CI_WORKLOAD_REQUESTS:-40}" "$APP_URL"
# The workload above plus the forced request below cover the live write path;
# keep the smoke helper out of this isolated run because it is a separate
# stack lifecycle/read-contract test and can race another local invocation.
# Force a uniquely scoped failure after readiness. The response header is the
# sole source of truth for this request; no older workload trace is eligible.
forced_headers="$(mktemp "${TMPDIR:-/tmp}/agentotel-forced-headers.XXXXXX")"
forced_body="$(mktemp "${TMPDIR:-/tmp}/agentotel-forced-body.XXXXXX")"
forced_status="$(curl -sS --max-time 15 -D "$forced_headers" -o "$forced_body" -w '%{http_code}' "$APP_URL/api/checkout?fail=1" || true)"
[[ "$forced_status" == 500 ]] || { echo "FAIL: forced checkout did not return HTTP 500 (status=$forced_status)" >&2; exit 1; }
trace="$(awk 'tolower($1) == "x-agentotel-trace-id:" { sub(/\r$/, "", $2); print tolower($2) }' "$forced_headers")"
trace_count="$(awk 'tolower($1) == "x-agentotel-trace-id:" { count++ } END { print count + 0 }' "$forced_headers")"
rm -f "$forced_headers" "$forced_body"
[[ "$trace_count" == 1 && "$trace" =~ ^[0-9a-f]{32}$ ]] || {
  echo "FAIL: forced checkout did not return exactly one valid X-AgentOTel-Trace-ID header" >&2
  exit 1
}
printf 'forced request trace header=%s\n' "$trace"
correlate_payload="$(jq -cn --arg trace "$trace" --arg project "$project_uuid" '{trace_id:$trace,project:$project}')"
printf '%s' "$correlate_payload" | jq -e --arg trace "$trace" --arg project "$project_uuid" '.trace_id == $trace and .project == $project' >/dev/null || {
  echo 'FAIL: correlation payload lost the exact trace or project UUID' >&2
  exit 1
}
printf 'correlation request scope project=%s project_bound=true\n' "$project_uuid"
correlation=''; last_correlation_summary='{}'; exact_error_seen=0
for _ in $(seq 1 "${CI_ERROR_POLL_SECONDS:-60}"); do
  errors_response="$(curl -sS -w $'\n__HTTP_STATUS__%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get "$GATEWAY_URL/v1/errors" \
    --data-urlencode 'service=sample-app' --data-urlencode "project=$project_uuid" --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' || true)"
  errors_status="${errors_response##*__HTTP_STATUS__}"
  errors="${errors_response%$'\n__HTTP_STATUS__'*}"
  if [[ "$errors_status" != 200 && "${errors_status_reported:-0}" != 1 ]]; then
    printf 'error query status=%s scope=%s\n' "$errors_status" "$project_uuid" >&2
    errors_status_reported=1
  fi
  if [[ "$errors_status" == 200 ]] && printf '%s' "$errors" | jq -e --arg trace "$trace" '[.. | objects | select((.trace_id // .traceID // empty) == $trace)] | length > 0' >/dev/null 2>&1; then
    exact_error_seen=1
  fi
  candidate_correlation="$(curl -sS --max-time 15 -X POST -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" -H 'Content-Type: application/json' --data "$correlate_payload" "$GATEWAY_URL/v1/correlate" || true)"
  last_correlation_summary="$(printf '%s' "$candidate_correlation" | jq -c '{schema_version,partial,backends:([.backends[]? | {name,status}]),warnings:(.warnings // [])}' 2>/dev/null || printf '%s' '{"decode":"invalid"}')"
  if printf '%s' "$candidate_correlation" | jq -e --arg trace "$trace" '.schema_version=="1.0" and .partial==false and ([.backends[]?.status] | length >= 3 and all(. == "ok")) and ((.data.correlation.spans // []) | length > 0) and ((.data.correlation.logs // []) | length > 0) and ((.data.correlation.metrics // []) | length > 0) and ([.data.correlation.logs[]? | select((.trace_id // .traceID // empty) == $trace)] | length > 0) and ([.. | objects | select((.trace_id // .traceID // empty) == $trace)] | length > 0)' >/dev/null 2>&1 && [[ "$exact_error_seen" == 1 ]]; then
    correlation="$candidate_correlation"; break
  fi
  sleep 1
done
if ! [[ "$trace" =~ ^[0-9a-f]{32}$ ]] || [[ -z "$correlation" ]]; then
  printf 'FAIL: exact forced trace did not fully correlate after bounded poll; trace=%s last=%s\n' "$trace" "$last_correlation_summary" >&2
  exit 1
fi
correlation_evidence="$(printf '%s' "$correlation" | jq -c '{backends:[.backends[]? | {name,status}],span_count:((.data.correlation.spans // []) | length),logs_present:(.data.correlation.logs != null),metrics_present:(.data.correlation.metrics != null)}')"
printf 'correlation evidence trace=%s exact_error=true %s\n' "$trace" "$correlation_evidence"
curl -fsS -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" "$GATEWAY_URL/v1/version" | jq -e '.schema_version=="1.0" and .api_min=="1.0" and .api_max=="1.0"'
printf '%s' "$correlation" | jq -e --arg trace "$trace" '.schema_version=="1.0" and .partial==false and ([.backends[]?.status] | length>=3 and all(. == "ok")) and ((.data.correlation.spans // []) | length > 0) and ((.data.correlation.logs // []) | length > 0) and ((.data.correlation.metrics // []) | length > 0) and ([.data.correlation.logs[]? | select((.trace_id // .traceID // empty) == $trace)] | length > 0) and ([.. | objects | select((.trace_id // .traceID // empty) == $trace)] | length > 0)'

# Exercise the live app -> Collector -> Victoria -> Gateway path with sensitive
# request fields and distinct order IDs. This black-box check complements the
# hermetic source/configuration checks and never addresses a backend directly.
"$ROOT/scripts/test-runtime-controls.sh" "$APP_URL" "$GATEWAY_URL" "$project_uuid" sample-app

dashboard_errors="$(curl -fsS --get -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" "$DASHBOARD_URL/api/errors" \
  --data-urlencode 'service=sample-app' --data-urlencode 'lookback=5m' --data-urlencode 'limit=100')"
printf '%s' "$dashboard_errors" | jq -e '
  .schema_version == "dashboard.v1" and .kind == "errors" and
  .scope.project_bound == true and .scope.service == "sample-app" and
  .partial == false and
  ([.backends[]?.name] | (index("logs") != null and index("traces") != null)) and
  ([.backends[]?.status] | all(. == "ok" or . == "no_matching_data" or . == "trace_not_stored" or . == "signal_not_observed"))
' >/dev/null || {
  echo 'FAIL: dashboard errors response did not preserve healthy bounded backend status scope' >&2
  exit 1
}
dashboard_correlation="$(curl -fsS -X POST -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" -H 'Content-Type: application/json' \
  --data "{\"trace_id\":\"$trace\"}" "$DASHBOARD_URL/api/correlate")"
printf '%s' "$dashboard_correlation" | jq -e --arg trace "$trace" '
  .schema_version == "dashboard.v1" and .kind == "correlate" and
  .scope.project_bound == true and .data.supported == true and
  .data.trace_id == $trace and .partial == false and
  ((.data.spans // []) | length > 0) and
  ((.data.logs // []) | length > 0) and
  ((.data.metrics // []) | length > 0) and
  ([.data.logs[]? | select(.trace_id == $trace)] | length > 0) and
  ([.backends[]?.name] | (index("traces") != null and index("logs") != null and index("metrics") != null)) and
  ([.backends[]?.status] | all(. == "ok" or . == "no_matching_data" or . == "trace_not_stored" or . == "signal_not_observed"))
' >/dev/null || {
  echo 'FAIL: dashboard could not render the same forced-error trace' >&2
  exit 1
}
! printf '%s%s' "$dashboard_errors" "$dashboard_correlation" | grep -Fq -- "$GATEWAY_QUERY_TOKEN" || {
  echo 'FAIL: dashboard trace/error response leaked the Gateway query credential' >&2
  exit 1
}
export DASHBOARD_TRACE_ID="$trace"

# Prove the partial-backend contract with a controlled, reversible outage.
compose stop victorialogs
outage_response="$(curl -fsS -w $'\n__HTTP_STATUS__%{http_code}' -H "Authorization: Bearer $GATEWAY_QUERY_TOKEN" --get "$GATEWAY_URL/v1/errors" \
  --data-urlencode 'service=sample-app' --data-urlencode "project=$project_uuid" --data-urlencode 'lookback=5m' --data-urlencode 'limit=100')"
outage_status="${outage_response##*__HTTP_STATUS__}"
outage_body="${outage_response%$'\n__HTTP_STATUS__'*}"
[[ "$outage_status" == 200 ]] || { echo "FAIL: VictoriaLogs outage context status=$outage_status" >&2; exit 1; }
# A partial response must identify the unavailable logs backend while retaining
# at least one healthy peer.  In particular, no_data is not an outage signal.
if ! printf '%s' "$outage_body" | jq -e '
  .schema_version == "1.0" and .partial == true and
  ([.backends[]? | select(.name == "logs" and (.status == "backend_unavailable" or .status == "timeout"))] | length == 1) and
  ([.backends[]? | select(.name != "logs" and (.status == "ok" or .status == "no_matching_data" or .status == "trace_not_stored" or .status == "signal_not_observed"))] | length >= 1) and
  ([.backends[]? | select(.name == "logs" and (.status == "no_data" or .status == "no_matching" or .status == "no_matching_data"))] | length == 0)
' >/dev/null; then
  echo 'FAIL: VictoriaLogs outage response did not identify a partial logs outage' >&2
  printf 'outage response (safe, truncated):\n%s\n' "${outage_body:0:4096}" >&2
  exit 1
fi
outage_backend_summary="$(printf '%s' "$outage_body" | jq -c '[.backends[]? | {name,status}]')"
printf 'partial outage evidence backend_status=%s\n' "$outage_backend_summary"
compose start victorialogs
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
recovery_backend_summary="$(printf '%s' "$recovery_body" | jq -c '[.backends[]? | {name,status}]')"
printf 'recovery evidence health=%s context_http=%s backend_status=%s\n' "$health_status" "$recovery_status" "$recovery_backend_summary"
[[ "${RUN_DASHBOARD_E2E:-0}" == 1 ]] || {
  echo 'FAIL: live integration requires RUN_DASHBOARD_E2E=1; backend-only success is not a complete CI proof' >&2
  exit 2
}
command -v npm >/dev/null 2>&1 || { echo 'FAIL: dashboard E2E requires npm' >&2; exit 1; }
dashboard_bootstrap_url="${DASHBOARD_URL}/#token=${DASHBOARD_CLIENT_TOKEN}"
ready_nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')"
[[ "$ready_nonce" =~ ^[0-9a-f]{32}$ ]] || { echo 'FAIL: unable to generate E2E readiness nonce' >&2; exit 2; }
ready_proof_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-ci-e2e-ready.XXXXXX")"
chmod 600 "$ready_proof_file"
printf '{"version":1,"kind":"agentotel.e2e-ready.v1","mode":"all","dashboard_status":"ready","project_id":"%s","compose_project":"%s","issued_at":%s,"nonce":"%s"}\n' \
  "$project_uuid" "$project" "$(date +%s)" "$ready_nonce" >"$ready_proof_file"
exec 9<"$ready_proof_file"
rm -f "$ready_proof_file"
export AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE=all
browser_rc=0
if CI=1 APP_URL="$APP_URL" DASHBOARD_URL="$DASHBOARD_URL" \
  AGENTOTEL_PROJECT_ID="$project_uuid" COMPOSE_PROJECT_NAME="$project" \
  DASHBOARD_TRACE_ID="$DASHBOARD_TRACE_ID" \
  DASHBOARD_BOOTSTRAP_URL="$dashboard_bootstrap_url" \
  DASHBOARD_E2E_AUTH_TOKEN="$DASHBOARD_CLIENT_TOKEN" \
  "$ROOT/scripts/run-browser-e2e.sh" all; then
  browser_rc=0
else
  browser_rc=$?
fi
exec 9<&-
(( browser_rc == 0 )) || exit "$browser_rc"
ci_failed=0
echo "PASS live integration project=$project stack_uuid=$uuid telemetry_project=$project_uuid ports=app:$APP_HOST_PORT ingest:$GATEWAY_INGEST_HOST_PORT query:$GATEWAY_QUERY_HOST_PORT dashboard:$DASHBOARD_HOST_PORT trace=$trace"
