#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
counts=$tmp/counts; mkdir -p "$counts"
fake_df=$tmp/df; cat >"$fake_df" <<'EOF'
#!/bin/sh
printf '%s\n' df >>"$COUNTS/df"
case "${DF_FIXTURE:-warn}" in
 ok) echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo '/fixture 1000 700 300 70% /' ;;
 warn) echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo '/fixture 1000 800 200 80% /' ;;
 critical) echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo '/fixture 1000 900 100 90% /' ;;
esac
EOF
chmod +x "$fake_df"
fake_curl=$tmp/curl; cat >"$fake_curl" <<'EOF'
#!/bin/sh
# Return only checked-in, hermetic gateway envelopes; never contact a backend.
printf '%s\n' "$*" >>"$COUNTS/curl"
case "$*" in *limit=500*) ;; *) exit 9 ;; esac
endpoint=; case "$*" in *v1/context*) endpoint=context ;; *v1/errors*) endpoint=errors ;; esac
if [ -n "$endpoint" ]; then
  : >"$COUNTS/$endpoint.started"
  spins=0
  while [ ! -f "$COUNTS/context.started" ] || [ ! -f "$COUNTS/errors.started" ]; do
    spins=$((spins + 1)); [ "$spins" -lt 100 ] || { : >"$COUNTS/barrier_timeout"; exit 98; }
    sleep 0.01
  done
fi
case "${STORAGE_FIXTURE:-ok}:$*" in
  ok:*v1/context*) printf '%s\n' '{"data":{"metrics":{"data":{"result":[{"metric":{"service_name":"sample-app","route":"/orders"}},{"metric":{"service_name":"sample-app","route":"/health"}}]}}},"partial":false}'; exit 0 ;;
  ok:*v1/errors*) printf '%s\n' '{"data":{"logs":{"data":[{"service_name":"sample-app"},{"service_name":"worker"},{"service_name":"sample-app"}]},"traces":{"data":[{"service_name":"sample-app","spans":[{"name":"checkout"},{"name":"checkout"}]},{"service_name":"worker","spans":[{"name":"poll"}]}]}},"partial":false}'; exit 0 ;;
  empty:*) case "$*" in *v1/context*) printf '%s\n' '{"data":{"metrics":{"data":{"result":[]}}},"partial":false}' ;; *v1/errors*) printf '%s\n' '{"data":{"logs":[],"traces":[]},"partial":false}' ;; esac ;;
  unavailable:*) exit 7 ;;
  malformed:*v1/context*) printf '%s\n' '{"data":{"metrics":{"data":{"result": [}}' ;;
  malformed:*v1/errors*) printf '%s\n' '{"data": [}' ;;
esac
EOF
chmod +x "$fake_curl"
real_jq=$(command -v jq)
fake_jq=$tmp/jq; cat >"$fake_jq" <<'EOF'
#!/bin/sh
printf '%s\n' jq >>"$COUNTS/jq"
exec "$REAL_JQ" "$@"
EOF
chmod +x "$fake_jq"
fake_docker=$tmp/docker; cat >"$fake_docker" <<'EOF'
#!/bin/sh
# Empty disposable volume inventory; this test must not inspect/remove host volumes.
printf '%s\n' "$*" >>"$COUNTS/docker"
case "${DOCKER_VOLUME_MODE:-empty}:$*" in
  fail:*"volume ls"*) exit 77 ;;
esac
case "$*" in *"volume inspect"*) exit 1;; esac
exit 0
EOF
chmod +x "$fake_docker"
count(){ [ -f "$counts/$1" ] && wc -l <"$counts/$1" | tr -d ' ' || printf '0'; }
reset_counts(){ : >"$counts/curl"; : >"$counts/jq"; : >"$counts/df"; : >"$counts/docker"; rm -f "$counts/context.started" "$counts/errors.started" "$counts/barrier_timeout"; }
assert_counts(){
  if [ "$(count curl)" = 2 ] && [ "$(count df)" = 1 ] && [ "$(count jq)" = 1 ] && [ ! -f "$counts/barrier_timeout" ]; then
    :
  else
    echo "FAIL call budget/parallel barrier curl=$(count curl) df=$(count df) jq=$(count jq)" >&2
    exit 1
  fi
}
run(){ set +e; hash -r 2>/dev/null || true; reset_counts; out=$(PATH="$tmp:$PATH" COUNTS="$counts" REAL_JQ="$real_jq" XDG_CONFIG_HOME="$tmp/c" XDG_DATA_HOME="$tmp/d" XDG_STATE_HOME="$tmp/s" GATEWAY_QUERY_TOKEN=test-query-token AGENTOTEL_DF_CMD="$fake_df" DF_FIXTURE="$1" STORAGE_FIXTURE=unavailable AGENTOTEL_JSON=1 AGENTOTEL_CURL_CMD="$fake_curl" "$root/libexec/agentotel/storage.sh" storage 2>&1); rc=$?; set -e; printf '%s %s\n' "$rc" "$out"; }
assert(){ expected=$1; shift; result=$(run "$@"); rc=${result%% *}; [ "$rc" = "$expected" ] || { echo "FAIL pressure $*: $result" >&2; exit 1; }; assert_counts; }
assert 0 ok; assert 1 warn; assert 2 critical

set +e
reset_counts
failure_output=$(PATH="$tmp:$PATH" COUNTS="$counts" REAL_JQ="$real_jq" XDG_CONFIG_HOME="$tmp/c" XDG_DATA_HOME="$tmp/d" XDG_STATE_HOME="$tmp/s" GATEWAY_QUERY_TOKEN=test-query-token DOCKER_VOLUME_MODE=fail AGENTOTEL_DF_CMD="$fake_df" AGENTOTEL_CURL_CMD="$fake_curl" AGENTOTEL_JSON=1 "$root/libexec/agentotel/storage.sh" storage 2>&1)
failure_rc=$?
set -e
[ "$failure_rc" -eq 2 ] || { echo "FAIL inventory failure rc=$failure_rc: $failure_output" >&2; exit 1; }
printf '%s' "$failure_output" | jq -e '.status=="unavailable" and .check=="volumes"' >/dev/null || { echo "FAIL inventory failure response: $failure_output" >&2; exit 1; }
if [ "$(count df)" = 0 ] && [ "$(count curl)" = 0 ]; then
  :
else
  echo "FAIL inventory failure queried after load failure df=$(count df) curl=$(count curl)" >&2
  exit 1
fi

project(){ fixture=$1; set +e; hash -r 2>/dev/null || true; reset_counts; output=$(PATH="$tmp:$PATH" COUNTS="$counts" REAL_JQ="$real_jq" XDG_CONFIG_HOME="$tmp/c" XDG_DATA_HOME="$tmp/d" XDG_STATE_HOME="$tmp/s" GATEWAY_QUERY_TOKEN=test-query-token AGENTOTEL_DF_CMD="$fake_df" DF_FIXTURE=ok STORAGE_FIXTURE="$fixture" AGENTOTEL_JSON=1 AGENTOTEL_CURL_CMD="$fake_curl" "$root/libexec/agentotel/storage.sh" storage 2>&1); rc=$?; set -e; [ "$rc" -eq 0 ] || { echo "FAIL projection $fixture rc=$rc: $output" >&2; exit 1; }; jq_expected=3; if [ "$fixture" = unavailable ]; then jq_expected=1; fi; if [ "$(count curl)" = 2 ] && [ "$(count df)" = 1 ] && [ "$(count jq)" = "$jq_expected" ] && [ ! -f "$counts/barrier_timeout" ]; then :; else echo "FAIL projection call budget/parallel barrier curl=$(count curl) df=$(count df) jq=$(count jq)" >&2; cat "$counts/jq" >&2; exit 1; fi; printf '%s' "$output"; }
assert_projection(){ fixture=$1; expected=$2; output=$(project "$fixture"); printf '%s' "$output" | jq -e . >/dev/null || { echo "FAIL $fixture: invalid JSON" >&2; exit 1; }; printf '%s' "$output" | jq -e "$expected" >/dev/null || { echo "FAIL $fixture: $expected ($output)" >&2; exit 1; }; }
assert_projection ok '.signals.ingest_rate.status=="ok" and .signals.ingest_rate.value==2 and .signals.ingest_rate.rate==(2/900) and .signals.ingest_rate.unit=="observed_evidence_rate" and .signals.ingest_rate.window_seconds==900 and .signals.ingest_rate.source=="gateway_context_projected_metrics" and (.signals.ingest_rate.interpretation|length)>0 and .signals.log_stream_churn.value==2 and .signals.log_stream_churn.rate==(2/900) and .signals.trace_service_span_churn.value.services==2 and .signals.trace_service_span_churn.value.span_names==2 and .signals.trace_service_span_churn.rate==(4/900) and .policy.max_items==500 and .policy.low_cardinality==true'
assert_projection empty '.signals.ingest_rate.status=="no_data" and .signals.ingest_rate.value==null and .signals.ingest_rate.rate==null and .signals.log_stream_churn.status=="no_data" and .signals.log_stream_churn.value==null'
assert_projection unavailable '.signals.ingest_rate.status=="unavailable" and .signals.ingest_rate.value==null and .signals.log_stream_churn.status=="unavailable" and .signals.trace_service_span_churn.value==null'
assert_projection malformed '.signals.ingest_rate.status=="unavailable" and .signals.log_stream_churn.status=="unavailable"'
if printf '%s' "$(project ok)" | grep -Eqi 'query_token|dev-query-token|127\.0\.0\.1:17777|https?://'; then echo 'FAIL projection leaked secret/backend URL' >&2; exit 1; fi
echo 'PASS storage pressure thresholds, parallel query/decode call budgets, and projection contract (hermetic fixtures; no host filling/backend queried)'
