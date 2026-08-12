#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; counts="$tmp/counts"; mkdir -p "$bin" "$counts"
real_jq=$(command -v jq)

cat >"$bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$COUNTS/docker"
case "$*" in
  'compose config --services') printf '%s\n' gateway otel-collector ;;
  'compose ps --status running --services') printf '%s\n' gateway ;;
  'volume ls --format '*)
    [ "${DOCKER_VOLUME_MODE:-existing}" = fail ] && exit 77
    [ "${DOCKER_VOLUME_MODE:-existing}" = empty ] && exit 0
    printf '%s\n' dev-observability_otelcol-queue dev-observability_victorialogs-data dev-observability_victoriametrics-data dev-observability_victoriatraces-data dev-observability_grafana-data ;;
  'volume inspect '* )
    for arg in "$@"; do
      case "$arg" in
        -f|--format) skip=1; continue;;
      esac
      [ "${skip:-0}" = 1 ] && { skip=0; continue; }
      case "$arg" in
        '{{*') continue;;
        dev-observability_*)
          if [ "${DOCKER_VOLUME_MODE:-existing}" = mismatched ]; then
            printf '%s\t%s\t%s\n' "$arg" other-stack other-project
          else
            printf '%s\t%s\t%s\n' "$arg" "$STACK_UUID" dev-observability
          fi ;;
      esac
    done
    ;;
  'volume create '*) : ;;
  *) echo "unexpected docker call: $*" >&2; exit 90 ;;
esac
EOF
chmod +x "$bin/docker"
cat >"$bin/df" <<'EOF'
#!/bin/sh
printf '%s\n' df >>"$COUNTS/df"
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' '/fixture 1000000 100 1999900 1% /'
EOF
chmod +x "$bin/df"
cat >"$bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$COUNTS/curl"
case "$*" in
  *v1/context*) printf '%s\n' '{"data":{"metrics":{"data":{"result":[{"metric":{"service_name":"sample-app"}}]}}},"partial":false}' ;;
  *v1/errors*) printf '%s\n' '{"data":{"logs":{"data":[{"service_name":"sample-app"}]},"traces":{"data":[{"service_name":"sample-app","spans":[{"name":"checkout"}]}]}},"partial":false}' ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$bin/curl"
cat >"$bin/jq" <<'EOF'
#!/bin/sh
printf '%s\n' jq >>"$COUNTS/jq"
exec "$REAL_JQ" "$@"
EOF
chmod +x "$bin/jq"

count() { [ -f "$counts/$1" ] && wc -l <"$counts/$1" | tr -d ' ' || printf '0'; }
count_docker_op() { [ -f "$counts/docker" ] && awk -v op="$1" '$0 ~ ("^" op " "){ n++ } END { print n + 0 }' "$counts/docker" || printf '0'; }
STACK_UUID=11111111-1111-4111-8111-111111111111
run_with_env() {
  env PATH="$bin:$PATH" COUNTS="$counts" STACK_UUID="$STACK_UUID" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" GATEWAY_QUERY_TOKEN=aaaaaaaa AGENTOTEL_DF_CMD="$bin/df" AGENTOTEL_CURL_CMD="$bin/curl" AGENTOTEL_ROOT="$root" AGENTOTEL_JSON=1 COMPOSE_PROJECT_NAME=dev-observability REAL_JQ="$real_jq" "$@"
}
mkdir -p "$tmp/state/agentotel"; printf '%s\n' "$STACK_UUID" >"$tmp/state/agentotel/stack.uuid"

# The pre-optimization implementation made 27 docker calls for a populated
# doctor inventory (per-volume existence + labels), 11 jq calls in storage,
# and 15 docker calls in setup (per-volume existence + labels). These counters
# are the regression budget for the batched/cache paths.
run_with_env "$root/libexec/agentotel/doctor.sh" >"$tmp/doctor.json"
[ "$(count docker)" -eq 4 ] || { echo "doctor docker calls: $(count docker), want 4" >&2; cat "$counts/docker" >&2; exit 1; }
[ "$(count_docker_op 'volume ls')" -eq 1 ] || { echo "doctor volume ls calls: $(count_docker_op 'volume ls'), want 1" >&2; exit 1; }
[ "$(count_docker_op 'volume inspect')" -eq 1 ] || { echo "doctor volume inspect calls: $(count_docker_op 'volume inspect'), want 1" >&2; exit 1; }
[ "$(grep -c 'com.agentotel.stack.*com.docker.compose.project' "$counts/docker")" -eq 1 ] || { echo 'doctor volume inspect did not batch both identity labels' >&2; exit 1; }
[ "$(count df)" -eq 1 ] || { echo "doctor df calls: $(count df), want 1" >&2; exit 1; }
[ "$(run_with_env sh -x "$root/libexec/agentotel/doctor.sh" >"$tmp/doctor-traced.json" 2>"$tmp/doctor.trace"; grep -c 'legacy_volume_list' "$tmp/doctor.trace")" -eq 1 ] || { echo 'doctor must call legacy volume listing once' >&2; exit 1; }
"$real_jq" -e . <"$tmp/doctor.json" >/dev/null

: >"$counts/docker"; : >"$counts/jq"; : >"$counts/curl"; : >"$counts/df"
run_with_env "$root/libexec/agentotel/storage.sh" storage >"$tmp/storage.json"
[ "$(count docker)" -eq 2 ] || { echo "storage docker calls: $(count docker), want 2" >&2; exit 1; }
[ "$(count curl)" -eq 2 ] || { echo "storage curl calls: $(count curl), want 2" >&2; exit 1; }
[ "$(count jq)" -eq 3 ] || { echo "storage jq calls: $(count jq), want 3" >&2; exit 1; }
"$real_jq" -e '.signals.ingest_rate.value == 1 and .signals.log_stream_churn.value == 1 and .signals.trace_service_span_churn.value.span_names == 1' <"$tmp/storage.json" >/dev/null

# A failed Docker volume inventory must fail closed before disk or gateway queries.
: >"$counts/docker"; : >"$counts/jq"; : >"$counts/curl"; : >"$counts/df"
export DOCKER_VOLUME_MODE=fail
if run_with_env "$root/libexec/agentotel/storage.sh" storage >"$tmp/storage-fail.json" 2>"$tmp/storage-fail.err"; then
  echo 'storage inventory failure unexpectedly succeeded' >&2; exit 1
fi
[ "$(count docker)" -eq 1 ] || { echo "storage failure docker calls: $(count docker), want 1" >&2; exit 1; }
[ "$(count curl)" -eq 0 ] || { echo 'storage inventory failure queried gateway' >&2; exit 1; }
[ "$(count df)" -eq 0 ] || { echo 'storage inventory failure queried disk' >&2; exit 1; }
"$real_jq" -e '.status == "unavailable" and .check == "volumes"' <"$tmp/storage-fail.json" >/dev/null || {
  echo 'storage inventory failure status missing' >&2; exit 1;
}
unset DOCKER_VOLUME_MODE

: >"$counts/docker"
run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup.out"
[ "$(count docker)" -lt 15 ] || { echo "setup docker calls: $(count docker), must improve on baseline 15" >&2; exit 1; }
[ "$(count docker)" -eq 2 ] || { echo "setup docker calls: $(count docker), want 2" >&2; exit 1; }
[ "$(count_docker_op 'volume ls')" -eq 1 ] || { echo "setup volume ls calls: $(count_docker_op 'volume ls'), want 1" >&2; exit 1; }
[ "$(count_docker_op 'volume inspect')" -eq 1 ] || { echo "setup volume inspect calls: $(count_docker_op 'volume inspect'), want 1" >&2; exit 1; }
[ "$(grep -c 'com.agentotel.stack.*com.docker.compose.project' "$counts/docker")" -eq 1 ] || { echo 'setup volume inspect did not batch both identity labels' >&2; exit 1; }
[ "$(cat "$tmp/setup.out")" = "$STACK_UUID" ] || { echo 'setup stack identity contract changed' >&2; exit 1; }

# Empty inventory is a valid result: setup creates exactly the allowlisted set.
: >"$counts/docker"
export DOCKER_VOLUME_MODE=empty
run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-empty.out"
[ "$(count_docker_op 'volume ls')" -eq 1 ] || { echo 'empty inventory volume ls calls changed' >&2; exit 1; }
[ "$(count_docker_op 'volume inspect')" -eq 0 ] || { echo 'empty inventory must not inspect volumes' >&2; exit 1; }
[ "$(count_docker_op 'volume create')" -eq 5 ] || { echo 'empty inventory must create five volumes' >&2; exit 1; }

# Existing but mismatched identity must fail closed before any create call.
: >"$counts/docker"
export DOCKER_VOLUME_MODE=mismatched
if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-mismatch.out" 2>"$tmp/setup-mismatch.err"; then
  echo 'mismatched volume identity unexpectedly succeeded' >&2; exit 1
fi
[ "$(count_docker_op 'volume create')" -eq 0 ] || { echo 'mismatched inventory attempted volume creation' >&2; exit 1; }

# An inventory command failure is not an empty inventory; setup must not create.
: >"$counts/docker"
export DOCKER_VOLUME_MODE=fail
if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-fail.out" 2>"$tmp/setup-fail.err"; then
  echo 'volume inventory failure unexpectedly succeeded' >&2; exit 1
fi
[ "$(count_docker_op 'volume create')" -eq 0 ] || { echo 'inventory failure attempted volume creation' >&2; exit 1; }
grep -q 'refusing to create' "$tmp/setup-fail.err" || { echo 'inventory failure message missing fail-closed reason' >&2; exit 1; }
if run_with_env "$root/libexec/agentotel/doctor.sh" >"$tmp/doctor-fail.json"; then
  echo 'doctor inventory failure unexpectedly succeeded' >&2; exit 1
fi
"$real_jq" -e '.status == "unavailable" and .check == "volumes"' <"$tmp/doctor-fail.json" >/dev/null || {
  echo 'doctor inventory failure status missing' >&2; exit 1;
}
unset DOCKER_VOLUME_MODE

echo 'PASS shell call budgets (doctor 27->4 docker; storage 11->3 jq; setup 15->2 docker) and JSON/status contracts'
