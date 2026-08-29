#!/usr/bin/env bash
# Start an isolated checkout stack and run the Make-managed browser journey.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
case "$mode" in
  all|app|dashboard) ;;
  *) echo "run-e2e: usage: $0 {all|app|dashboard}" >&2; exit 2 ;;
esac

fail() { echo "run-e2e: $*" >&2; exit 1; }

dashboard_token_distinct() {
  local token="$1"
  if [[ -n "${GATEWAY_QUERY_TOKEN:-}" ]]; then
    [[ "$token" != "$GATEWAY_QUERY_TOKEN" ]]
    return
  fi
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 "$ROOT/bin/obs" credentials run -- \
    sh -c "[ \"\$GATEWAY_QUERY_TOKEN\" != \"\$1\" ]" sh "$token" >/dev/null 2>&1
}
generate_dashboard_token() {
  local token
  for _ in 1 2 3; do
    token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$token" =~ ^[0-9a-f]{64}$ ]] && dashboard_token_distinct "$token"; then
      printf '%s' "$token"
      return 0
    fi
  done
  fail 'unable to generate a distinct dashboard client token'
}

# Make E2E invocations own their project name. COMPOSE_PROJECT_NAME from a
# caller is never consulted; the project remains short enough for Docker names.
run_id="${GITHUB_RUN_ID:-local}"
attempt="${GITHUB_RUN_ATTEMPT:-0}"
run_id="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"
attempt="$(printf '%s' "$attempt" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"
[[ -n "$run_id" ]] || run_id=local
[[ -n "$attempt" ]] || attempt=0
project="agentotel-e2e-${run_id}-${attempt}-$(date +%s)-$$"
project="${project:0:63}"
project="${project%-}"
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || fail 'generated Compose project is invalid'

# Initialize the checkout's project metadata before the Compose boundary resolves
# and validates the UUID used by the generated project.
unset COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR COMPOSE_PROFILES COMPOSE_PROJECT_NAME
project_uuid="$(AGENTOTEL_DEV_MODE=1 "$ROOT/bin/obs" project ensure)"
[[ "$project_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail 'workspace project resolver returned a non-UUIDv4 project'

requested_gateway_ingest_port="${GATEWAY_INGEST_HOST_PORT:-}"
requested_gateway_query_port="${GATEWAY_QUERY_HOST_PORT:-}"
requested_app_port="${APP_HOST_PORT:-}"
requested_dashboard_port="${DASHBOARD_HOST_PORT:-}"
. "$ROOT/scripts/port-selection.sh"
port_selection_select || fail 'unable to select required loopback ports'
printf 'run-e2e: selected loopback ports ingest=%s query=%s app=%s dashboard=%s\n' \
  "$GATEWAY_INGEST_HOST_PORT" "$GATEWAY_QUERY_HOST_PORT" "$APP_HOST_PORT" "$DASHBOARD_HOST_PORT"

compose_raw() {
  AGENTOTEL_EXPOSE_TRACE_ID_HEADER=1 \
  "$ROOT/scripts/make-compose.sh" --project "$project" compose "$@"
}

# Make owns this isolated lifecycle while the canonical setup command owns
# identity, credentials, and external-volume creation.
volumes=("${project}_otelcol-queue" "${project}_victorialogs-data" "${project}_victoriametrics-data" "${project}_victoriatraces-data")
networks=("${project}_default" "${project}_edge" "${project}_backend" "${project}_dashboard")
setup_attempted=0
compose_attempted=0
ci_failed=1
. "$ROOT/scripts/ci-resource-guard.sh"
ci_resource_inventory_preflight || exit 1
trap ci_resource_cleanup EXIT
setup_attempted=1
uuid="$(env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
  AGENTOTEL_DEV_MODE=1 COMPOSE_PROJECT_NAME="$project" \
  "$ROOT/bin/obs" setup)"
DASHBOARD_CLIENT_TOKEN="$(generate_dashboard_token)"
export DASHBOARD_CLIENT_TOKEN
for volume in "${volumes[@]}"; do
  ci_resource_exact_volume_labels "$volume" || fail "setup did not create correctly labeled volume $volume"
done

profiles=()
case "$mode" in
  all) profiles=(--profile demo --profile dashboard) ;;
  app) profiles=(--profile demo) ;;
  # The dashboard journey exercises live errors and trace correlation, so it
  # needs the bundled demo app as a telemetry producer even though only the
  # dashboard spec is executed.
  dashboard) profiles=(--profile demo --profile dashboard) ;;
esac
compose_attempted=1
compose_raw "${profiles[@]}" up -d --build --force-recreate

app_url="${APP_URL:-http://127.0.0.1:${APP_HOST_PORT:-3000}}"
gateway_url="${GATEWAY_URL:-http://127.0.0.1:${GATEWAY_QUERY_HOST_PORT:-17777}}"
dashboard_url="${DASHBOARD_URL:-http://127.0.0.1:${DASHBOARD_HOST_PORT:-3001}}"
if ! dashboard_url="$("$ROOT/scripts/validate-dashboard-url.sh" "$dashboard_url" "${DASHBOARD_HOST_PORT:-3001}" 2>&1)"; then
  fail "$dashboard_url"
fi
bounded_curl() {
  local deadline="$1"
  shift
  curl "$@" >/dev/null 2>&1 &
  bounded_pid=$!
  bounded_rc=0
  while kill -0 "$bounded_pid" 2>/dev/null; do
    if (( $(date +%s) >= deadline )); then
      kill "$bounded_pid" 2>/dev/null || :
      wait "$bounded_pid" 2>/dev/null || :
      bounded_rc=124
      break
    fi
    sleep .05
  done
  if [ "$bounded_rc" -eq 0 ]; then
    wait "$bounded_pid" 2>/dev/null || bounded_rc=$?
  fi
  return "$bounded_rc"
}
bounded_curl_output() {
  local deadline="$1" output_file="$2"
  shift 2
  : >"$output_file"
  curl "$@" >"$output_file" 2>/dev/null &
  bounded_pid=$!
  bounded_rc=0
  while kill -0 "$bounded_pid" 2>/dev/null; do
    if (( $(date +%s) >= deadline )); then
      kill "$bounded_pid" 2>/dev/null || :
      wait "$bounded_pid" 2>/dev/null || :
      bounded_rc=124
      break
    fi
    sleep .05
  done
  if [ "$bounded_rc" -eq 0 ]; then
    wait "$bounded_pid" 2>/dev/null || bounded_rc=$?
  fi
  return "$bounded_rc"
}
wait_url() {
  local url="$1" label="$2" timeout="${E2E_READY_TIMEOUT:-90}" remaining curl_timeout
  [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || fail 'E2E_READY_TIMEOUT must be a positive integer'
  local ready_deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < ready_deadline )); do
    remaining=$(( ready_deadline - $(date +%s) ))
    curl_timeout=$(( remaining < 5 ? remaining : 5 ))
    if bounded_curl "$ready_deadline" --connect-timeout "$(( curl_timeout < 2 ? curl_timeout : 2 ))" --max-time "$curl_timeout" -fsS "$url"; then return 0; fi
    remaining=$(( ready_deadline - $(date +%s) ))
    (( remaining > 0 )) && sleep .1
  done
  fail "$label did not become ready at $url before ${timeout}s"
}

if [[ "$mode" == all || "$mode" == app || "$mode" == dashboard ]]; then
  wait_url "$app_url/health" 'sample app'
fi
if [[ "$mode" == all || "$mode" == dashboard ]]; then
  # Seed all three stores before the dashboard journey. The service selector
  # must exercise observed live data rather than an empty-start race.
  env -u DASHBOARD_CLIENT_TOKEN "$ROOT/workload/run.sh" "${E2E_WORKLOAD_REQUESTS:-20}" "$app_url"
  # The dashboard live journey must follow the exact forced failure it will
  # render; never fall back to an older workload trace.
  forced_headers="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-headers.XXXXXX")"
  forced_body="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-body.XXXXXX")"
  forced_status_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-status.XXXXXX")"
  forced_deadline=$(( $(date +%s) + 15 ))
  forced_rc=0
  bounded_curl_output "$forced_deadline" "$forced_status_file" -sS --connect-timeout 5 --max-time 15 \
    -D "$forced_headers" -o "$forced_body" -w '%{http_code}' "$app_url/api/checkout?fail=1" || forced_rc=$?
  forced_status=
  if [ "$forced_rc" -eq 0 ]; then
    forced_status="$(tr -d '\\r\\n' <"$forced_status_file")"
  fi
  trace="$(awk 'tolower($1) == "x-agentotel-trace-id:" { sub(/\r$/, "", $2); print tolower($2) }' "$forced_headers")"
  trace_count="$(awk 'tolower($1) == "x-agentotel-trace-id:" { count++ } END { print count + 0 }' "$forced_headers")"
  rm -f "$forced_headers" "$forced_body" "$forced_status_file"
  [[ "$forced_status" == 500 && "$trace_count" == 1 && "$trace" =~ ^[0-9a-f]{32}$ ]] || {
    fail "forced dashboard trace request was not an exact HTTP 500 with one valid trace header"
  }
  printf 'run-e2e: forced trace=%s status=%s header_count=%s\n' "$trace" "$forced_status" "$trace_count"
  export DASHBOARD_TRACE_ID="$trace"
  # Collector and backend ingestion are asynchronous. Wait for the exact trace
  # to become a supported dashboard view before launching Playwright, rather
  # than allowing a transient "Trace shape is unavailable" state to race it.
  trace_ready=0
  correlation_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-correlation.XXXXXX")"
  errors_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-errors.XXXXXX")"
  trace_timeout="${E2E_READY_TIMEOUT:-90}"
  [[ "$trace_timeout" =~ ^[0-9]+$ && "$trace_timeout" -gt 0 ]] || fail 'E2E_READY_TIMEOUT must be a positive integer'
  trace_deadline=$(( $(date +%s) + trace_timeout ))
  while (( $(date +%s) < trace_deadline )); do
    trace_remaining=$(( trace_deadline - $(date +%s) ))
    trace_curl_timeout=$(( trace_remaining < 5 ? trace_remaining : 5 ))
    if (( trace_curl_timeout > 0 )); then
      bounded_curl_output "$trace_deadline" "$correlation_file" -sS --connect-timeout "$(( trace_curl_timeout < 2 ? trace_curl_timeout : 2 ))" --max-time "$trace_curl_timeout" \
        -X POST -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" -H 'Content-Type: application/json' \
        --data "{\"trace_id\":\"$trace\"}" "$dashboard_url/api/correlate" || :
    fi
    trace_remaining=$(( trace_deadline - $(date +%s) ))
    trace_curl_timeout=$(( trace_remaining < 5 ? trace_remaining : 5 ))
    if (( trace_curl_timeout > 0 )); then
      bounded_curl_output "$trace_deadline" "$errors_file" -sS --connect-timeout "$(( trace_curl_timeout < 2 ? trace_curl_timeout : 2 ))" --max-time "$trace_curl_timeout" \
        -G -H "Authorization: Dashboard $DASHBOARD_CLIENT_TOKEN" \
        --data-urlencode 'service=sample-app' --data-urlencode 'lookback=5m' --data-urlencode 'limit=100' \
        "$dashboard_url/api/errors" || :
    fi
    # Supported is not evidence by itself: the exact forced request must have
    # nonempty spans, logs, metrics, and an error record carrying its trace ID.
    if "$ROOT/scripts/check-trace-evidence.sh" "$trace" "$correlation_file" "$errors_file" >/dev/null 2>&1; then
      trace_ready=1
      break
    fi
    trace_remaining=$(( trace_deadline - $(date +%s) ))
    if (( trace_remaining > 0 )); then
      sleep_for=$(( trace_remaining < 1 ? trace_remaining : 1 ))
      sleep "$sleep_for"
    fi
  done
  rm -f "$correlation_file" "$errors_file"
  [[ "$trace_ready" == 1 ]] || fail "exact dashboard trace did not become queryable with complete signal evidence before E2E timeout"
  # The API check proves the process, same-origin proxy, and Gateway query path.
  DASHBOARD_URL="$dashboard_url" DASHBOARD_CLIENT_TOKEN="$DASHBOARD_CLIENT_TOKEN" "$ROOT/scripts/dashboard-readiness.sh"
fi

# Exercise the running telemetry path with a sensitive canary and many distinct
# order IDs. The helper loads the query credential safely and uses only bounded
# Gateway endpoints; this is separate from the fake npm command-contract gate.
env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
  AGENTOTEL_DEV_MODE=1 GATEWAY_URL="$gateway_url" \
  "$ROOT/bin/obs" credentials run -- \
  "$ROOT/scripts/test-runtime-controls.sh" "$app_url" "$gateway_url" "$project_uuid" sample-app

export APP_URL="$app_url" DASHBOARD_URL="$dashboard_url" \
  DASHBOARD_BOOTSTRAP_URL="$dashboard_url/#token=$DASHBOARD_CLIENT_TOKEN" \
  DASHBOARD_E2E_AUTH_TOKEN="$DASHBOARD_CLIENT_TOKEN"
# Hand Playwright an unlinked inherited capability rather than a caller-set
# readiness marker. The proof binds the browser run to this lifecycle's mode,
# Compose project, telemetry project, and completed Dashboard/runtime stage.
ready_nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')"
[[ "$ready_nonce" =~ ^[0-9a-f]{32}$ ]] || fail 'unable to generate E2E readiness nonce'
dashboard_status=not_required
if [[ "$mode" == all || "$mode" == dashboard ]]; then
  dashboard_status=ready
fi
ready_proof_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-e2e-ready.XXXXXX")"
chmod 600 "$ready_proof_file"
printf '{"version":1,"kind":"agentotel.e2e-ready.v1","mode":"%s","dashboard_status":"%s","project_id":"%s","compose_project":"%s","issued_at":%s,"nonce":"%s"}\n' \
  "$mode" "$dashboard_status" "$project_uuid" "$project" "$(date +%s)" "$ready_nonce" >"$ready_proof_file"
exec 9<"$ready_proof_file"
rm -f "$ready_proof_file"
export AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE="$mode"
browser_rc=0
if COMPOSE_PROJECT_NAME="$project" AGENTOTEL_PROJECT_ID="$project_uuid" \
  "$ROOT/scripts/run-browser-e2e.sh" "$mode"; then
  browser_rc=0
else
  browser_rc=$?
fi
exec 9<&-
(( browser_rc == 0 )) || exit "$browser_rc"
ci_failed=0
