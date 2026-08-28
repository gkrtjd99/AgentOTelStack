#!/usr/bin/env bash
# Prove the dashboard's Gateway-backed query path is ready.
set -Eeuo pipefail

url="${DASHBOARD_URL:-http://127.0.0.1:${DASHBOARD_HOST_PORT:-3001}}"
timeout="${DASHBOARD_READY_TIMEOUT:-90}"
client_token="${DASHBOARD_CLIENT_TOKEN:-}"

fail() {
  echo "dashboard-readiness: $*" >&2
  exit 1
}

if ! url="$("$(dirname "$0")/validate-dashboard-url.sh" "$url" "${DASHBOARD_HOST_PORT:-3001}" 2>&1)"; then
  fail "$url"
fi
[[ "$client_token" =~ ^[0-9a-f]{64}$ ]] || fail 'DASHBOARD_CLIENT_TOKEN must be exactly 64 lowercase hexadecimal characters'
[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || fail 'DASHBOARD_READY_TIMEOUT must be a positive integer'

# A healthy empty query is valid. Operational failures and malformed envelopes
# are not; this helper intentionally proves the same-origin proxy and Gateway
# query path rather than merely checking the static root. The timeout is a
# wall-clock deadline, not a count of attempts.
deadline=$(( $(date +%s) + timeout ))
run_bounded_curl(){
  bounded_status_file=$1
  shift
  curl "$@" >"$bounded_status_file" 2>/dev/null &
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
while (( $(date +%s) < deadline )); do
  remaining=$(( deadline - $(date +%s) ))
  curl_timeout=$(( remaining < 8 ? remaining : 8 ))
  body_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-dashboard-ready.XXXXXX")"
  status_file="$(mktemp "${TMPDIR:-/tmp}/agentotel-dashboard-ready-status.XXXXXX")"
  curl_rc=0
  run_bounded_curl "$status_file" --connect-timeout "$(( curl_timeout < 2 ? curl_timeout : 2 ))" --max-time "$curl_timeout" -sS -o "$body_file" -w '%{http_code}' \
    -H "Authorization: Dashboard $client_token" "$url/api/services" || curl_rc=$?
  status=000
  if [ "$curl_rc" -eq 0 ]; then
    status="$(tr -d '\r\n' <"$status_file")"
    [ -n "$status" ] || status=000
  fi
  rm -f "$status_file"
  if [[ "$status" == 200 ]] && jq -e '
    .schema_version == "dashboard.v1" and
    .kind == "services" and
    (.scope.project_bound == true) and
    (.partial == false) and
    (.backends | type == "array" and length > 0) and
    ([.backends[] | .name] | (index("logs") != null and index("metrics") != null)) and
    ([.backends[] | .status] | all(. == "ok" or . == "no_matching_data"))
  ' <"$body_file" >/dev/null 2>&1; then
    rm -f "$body_file"
    printf 'dashboard-readiness: PASS url=%s backend_query=ready\n' "$url"
    exit 0
  fi
  if [[ "$status" != 000 && "$status" != 502 && "$status" != 503 ]]; then
    # Keep one bounded body for diagnosis, without ever printing credentials.
    printf 'dashboard-readiness: retry http=%s body=' "$status" >&2
    tr '\n' ' ' <"$body_file" | cut -c1-512 >&2
    printf '\n' >&2
  fi
  rm -f "$body_file"
  remaining=$(( deadline - $(date +%s) ))
  if (( remaining > 0 )); then
    sleep 1
  fi
done
fail "Gateway-backed /api/services did not become a complete dashboard.v1 response at $url before ${timeout}s"
