#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
. "$root/libexec/agentotel/common.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; counts="$tmp/counts"; mkdir -p "$bin" "$counts"
# This fixture is generated once from the shared contract and drives both the
# read-only inventory and setup fake-Docker paths below.
agentotel_active_volume_names dev-observability >"$tmp/active-volumes"
fixture_count=$(awk 'NF { count++ } END { print count + 0 }' "$tmp/active-volumes")
[ "$fixture_count" -eq 4 ] || { echo "canonical active volume fixture count: $fixture_count, want 4" >&2; exit 1; }
partial_mismatch_volume=$(sed -n '2p' "$tmp/active-volumes")
real_jq=$(command -v jq)

cat >"$bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$COUNTS/docker"
mode=${DOCKER_VOLUME_MODE:-existing}
volume_state=${VOLUME_STATE_DIR:?}
mkdir -p "$volume_state"
volume_labels() {
  name=$1
  # Inspect is a read of persisted fake Docker state. An absent object is an
  # error; never fabricate labels for a name merely because it is allowlisted.
  [ ! -L "$volume_state/$name" ] || return 1
  [ -f "$volume_state/$name" ] || return 1
  cat "$volume_state/$name"
}
write_inventory_fixture() {
  fixture_kind=$1
  while IFS= read -r fixture_name; do
    [ -n "$fixture_name" ] || continue
    if [ "$fixture_kind" = mismatched ] || { [ "$fixture_kind" = partial ] && [ "$fixture_name" = "$PARTIAL_MISMATCH_VOLUME" ]; }; then
      printf '%s|%s\n' other-stack other-project >"$volume_state/$fixture_name"
    else
      printf '%s|%s\n' "$STACK_UUID" dev-observability >"$volume_state/$fixture_name"
    fi
  done <"$ACTIVE_VOLUME_FILE"
}
case "$*" in
  'compose config --services') printf '%s\n' gateway otel-collector ;;
  'compose ps --status running --services') printf '%s\n' gateway ;;
  'volume ls --format '*)
    [ "$mode" = fail ] && exit 77
    case "$mode" in
      empty|post-mismatch|create-error|no-created-object|wrong-name|wrong-label) exit 0 ;;
      mismatched) write_inventory_fixture mismatched ;;
      partial-mismatch) write_inventory_fixture partial ;;
      existing) write_inventory_fixture valid ;;
    esac
    for state_file in "$volume_state"/*; do
      [ -f "$state_file" ] || continue
      basename "$state_file"
    done ;;
  'volume inspect '* )
    template=''; names=''; skip=0
    for arg in "$@"; do
      if [ "$skip" -eq 1 ]; then template=$arg; skip=0; continue; fi
      case "$arg" in
        -f|--format) skip=1; continue;;
        '{{*') template=$arg; continue;;
        dev-observability_*) names="${names}${arg}
";;
      esac
    done
    old_ifs=$IFS; IFS='
'
    for arg in $names; do
      [ -n "$arg" ] || continue
      labels=$(volume_labels "$arg") || exit 1
      stack=$(printf '%s\n' "$labels" | cut -d'|' -f1)
      owner=$(printf '%s\n' "$labels" | cut -d'|' -f2)
      case "$template" in
        *com.agentotel.stack*com.docker.compose.project*)
          case "${FORMAT_VARIANT:-actual-tab}" in
            literal-backslash-t) printf '%s\\t%s\\t%s\n' "$arg" "$stack" "$owner" ;;
            actual-tab) printf '%s\t%s\t%s\n' "$arg" "$stack" "$owner" ;;
            pipe) printf '%s|%s|%s\n' "$arg" "$stack" "$owner" ;;
            *) echo "unknown FORMAT_VARIANT" >&2; exit 92 ;;
          esac
          ;;
        *com.agentotel.stack*) printf '%s\n' "$stack" ;;
        *com.docker.compose.project*) printf '%s\n' "$owner" ;;
        *) printf '%s|%s\n' "$stack" "$owner" ;;
      esac
    done
    IFS=$old_ifs
    ;;
  'volume create '*)
    stack=''; owner=''; name=''; skip=0
    for arg in "$@"; do
      if [ "$skip" -eq 1 ]; then
        case "$arg" in
          com.agentotel.stack=*) stack=${arg#*=};;
          com.docker.compose.project=*) owner=${arg#*=};;
        esac
        skip=0
        continue
      fi
      case "$arg" in
        --label) skip=1;;
        dev-observability_*) name=$arg;;
      esac
    done
    [ -n "$name" ] || exit 93
    case "$mode" in
      create-error) exit 91 ;;
      no-created-object) printf '%s\n' "$name"; exit 0 ;;
      wrong-name)
        printf '%s|%s\n' "$stack" "$owner" >"$volume_state/${name}-wrong"
        printf '%s\n' "${name}-wrong"
        ;;
      post-mismatch|wrong-label)
        printf '%s|%s\n' other-stack other-project >"$volume_state/$name"
        printf '%s\n' "$name"
        ;;
      *)
        printf '%s|%s\n' "$stack" "$owner" >"$volume_state/$name"
        printf '%s\n' "$name"
        ;;
    esac
    ;;
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
export AGENTOTEL_STACK_UUID="$STACK_UUID"
run_with_env() {
  env PATH="$bin:$PATH" COUNTS="$counts" STACK_UUID="${AGENTOTEL_STACK_UUID:-$STACK_UUID}" ACTIVE_VOLUME_FILE="$tmp/active-volumes" PARTIAL_MISMATCH_VOLUME="$partial_mismatch_volume" VOLUME_STATE_DIR="$tmp/volume-state" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" GATEWAY_QUERY_TOKEN=aaaaaaaa AGENTOTEL_DF_CMD="$bin/df" AGENTOTEL_CURL_CMD="$bin/curl" AGENTOTEL_ROOT="$root" AGENTOTEL_JSON=1 COMPOSE_PROJECT_NAME=dev-observability REAL_JQ="$real_jq" "$@"
}
clear_volume_state() { rm -rf "$tmp/volume-state"; mkdir -p "$tmp/volume-state"; }
populate_volume_state() {
  clear_volume_state
  while IFS= read -r volume_name; do
    [ -n "$volume_name" ] || continue
    printf '%s|%s\n' "$STACK_UUID" dev-observability >"$tmp/volume-state/$volume_name"
  done <"$tmp/active-volumes"
}
mkdir -p "$tmp/state/agentotel"; printf '%s\n' "$STACK_UUID" >"$tmp/state/agentotel/stack.uuid"
populate_volume_state

# The pre-optimization implementation made 27 docker calls for a populated
# doctor inventory (per-volume existence + labels), 11 jq calls in storage,
# and 15 docker calls in setup (per-volume existence + labels). These counters
# cover the batched/cache paths plus setup's mandatory post-create verification.
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
populate_volume_state
run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup.out"
[ "$(count docker)" -lt 15 ] || { echo "setup docker calls: $(count docker), must improve on baseline 15" >&2; exit 1; }
[ "$(count docker)" -eq 3 ] || { echo "setup docker calls: $(count docker), want 3 (preflight + post-verify)" >&2; exit 1; }
[ "$(count_docker_op 'volume ls')" -eq 1 ] || { echo "setup volume ls calls: $(count_docker_op 'volume ls'), want 1" >&2; exit 1; }
[ "$(count_docker_op 'volume inspect')" -eq 2 ] || { echo "setup volume inspect calls: $(count_docker_op 'volume inspect'), want 2" >&2; exit 1; }
[ "$(grep -c 'com.agentotel.stack.*com.docker.compose.project' "$counts/docker")" -eq 2 ] || { echo 'setup volume inspections did not batch both identity labels' >&2; exit 1; }
[ "$(cat "$tmp/setup.out")" = "$STACK_UUID" ] || { echo 'setup stack identity contract changed' >&2; exit 1; }

# Docker implementations have emitted both actual tabs and the literal
# backslash-t spelling for legacy templates. The portable delimiter and parser
# must accept both forms, as well as the new literal-pipe formatter output.
for FORMAT_VARIANT in literal-backslash-t pipe; do
  export FORMAT_VARIANT
  : >"$counts/docker"
  populate_volume_state
  run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-$FORMAT_VARIANT.out"
  [ "$(cat "$tmp/setup-$FORMAT_VARIANT.out")" = "$STACK_UUID" ] || {
    echo "setup formatter variant failed: $FORMAT_VARIANT" >&2; exit 1;
  }
done
export FORMAT_VARIANT=actual-tab

# Empty inventory is a valid result: setup creates exactly the allowlisted set.
# An explicitly supplied UUID bootstraps the persisted identity and every new
# volume label; it cannot replace an identity that already exists.
: >"$counts/docker"
clear_volume_state
bootstrap_uuid=33333333-3333-4333-8333-333333333333
rm -f "$tmp/state/agentotel/stack.uuid"
export AGENTOTEL_STACK_UUID="$bootstrap_uuid" DOCKER_VOLUME_MODE=empty
run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-empty.out"
[ "$(cat "$tmp/state/agentotel/stack.uuid")" = "$bootstrap_uuid" ] || { echo 'explicit stack UUID was not persisted' >&2; exit 1; }
[ "$(count_docker_op 'volume ls')" -eq 1 ] || { echo 'empty inventory volume ls calls changed' >&2; exit 1; }
[ "$(count_docker_op 'volume inspect')" -eq 1 ] || { echo 'empty inventory must post-verify all created volumes' >&2; exit 1; }
[ "$(count_docker_op 'volume create')" -eq 4 ] || { echo 'empty inventory must create four active volumes' >&2; exit 1; }
[ "$(grep -c "com.agentotel.stack=$bootstrap_uuid" "$counts/docker")" -eq 4 ] || { echo 'explicit stack UUID was not applied to every created volume' >&2; exit 1; }
export AGENTOTEL_STACK_UUID="$bootstrap_uuid"

# Existing but mismatched identity must fail closed before any create call.
: >"$counts/docker"
clear_volume_state
export DOCKER_VOLUME_MODE=mismatched
if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-mismatch.out" 2>"$tmp/setup-mismatch.err"; then
  echo 'mismatched volume identity unexpectedly succeeded' >&2; exit 1
fi
[ "$(count_docker_op 'volume create')" -eq 0 ] || { echo 'mismatched inventory attempted volume creation' >&2; exit 1; }

# A mixed inventory (one valid and one mismatched existing volume) must also
# fail before creating any missing resource.
: >"$counts/docker"
clear_volume_state
export DOCKER_VOLUME_MODE=partial-mismatch
if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-partial-mismatch.out" 2>"$tmp/setup-partial-mismatch.err"; then
  echo 'partial mismatched inventory unexpectedly succeeded' >&2; exit 1
fi
[ "$(count_docker_op 'volume create')" -eq 0 ] || { echo 'partial mismatch attempted volume creation' >&2; exit 1; }

# Created resources are not trusted until the complete post-create inspection
# confirms their labels.
: >"$counts/docker"
clear_volume_state
export DOCKER_VOLUME_MODE=post-mismatch
if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-post-mismatch.out" 2>"$tmp/setup-post-mismatch.err"; then
  echo 'post-create label mismatch unexpectedly succeeded' >&2; exit 1
fi
[ "$(count_docker_op 'volume create')" -eq 4 ] || { echo 'post-create verification fixture did not create four volumes' >&2; exit 1; }
grep -q 'post-create volume identity' "$tmp/setup-post-mismatch.err" || { echo 'post-create mismatch reason missing' >&2; exit 1; }

# A fake create must be observable: an error, a fabricated/no-object result,
# a wrong object name, and wrong labels all fail closed rather than passing a
# no-op create/inspect implementation.
for create_mode in create-error no-created-object wrong-name wrong-label; do
  : >"$counts/docker"
  clear_volume_state
  export DOCKER_VOLUME_MODE="$create_mode"
  if run_with_env "$root/libexec/agentotel/setup.sh" >"$tmp/setup-$create_mode.out" 2>"$tmp/setup-$create_mode.err"; then
    echo "volume create fixture unexpectedly succeeded: $create_mode" >&2
    exit 1
  fi
  case "$create_mode" in
    create-error)
      [ "$(count_docker_op 'volume create')" -eq 1 ] || { echo 'create-error did not stop at the first create' >&2; exit 1; }
      grep -q 'unable to create volume' "$tmp/setup-$create_mode.err" || { echo 'create-error diagnostic missing' >&2; exit 1; }
      ;;
    *)
      [ "$(count_docker_op 'volume create')" -eq 4 ] || { echo "$create_mode did not attempt four creates" >&2; exit 1; }
      grep -q 'post-create volume identity' "$tmp/setup-$create_mode.err" || { echo "$create_mode diagnostic missing" >&2; exit 1; }
      ;;
  esac
done

# An inventory command failure is not an empty inventory; setup must not create.
: >"$counts/docker"
clear_volume_state
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

echo 'PASS shell call budgets (doctor 27->4 docker; storage 11->3 jq; setup preflight+verify batched) and JSON/status contracts'
