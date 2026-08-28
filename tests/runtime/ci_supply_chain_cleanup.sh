#!/bin/sh
# Exercise exact-label supply-chain cleanup with fake Docker. No real Docker
# daemon or other Compose project is touched.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-cleanup-test.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/bin" "$t/state"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_DOCKER_STATE:?}
scenario=${FAKE_DOCKER_SCENARIO:?}
project=${COMPOSE_PROJECT_NAME:-agentotel-test}
printf '%s\n' "$*" >>"$state/calls"
cmd=${1:-}; shift || :
fail_for() {
  [ "$scenario" != "$1" ] || { printf 'fake Docker operational error: %s\n' "$1" >&2; exit 42; }
}
lookup_label() {
  field=$1; record=$2
  old_ifs=$IFS; IFS='|'; set -- $record; IFS=$old_ifs
  case "$field" in project) printf '%s' "$2" ;; stack) printf '%s' "$3" ;; name) printf '%s' "$1" ;; esac
}
case "$cmd" in
  compose)
    case " $* " in
      *' down '*)
        fail_for down-error
        : >"$state/down-called"
        if [ "$scenario" != residual ]; then : >"$state/containers"; : >"$state/networks"; fi
        ;;
      *) echo "unexpected compose operation: $*" >&2; exit 2;;
    esac
    ;;
  ps)
    fail_for container-list-error
    while [ "$#" -gt 0 ]; do
      case "$1" in --filter) filter=$2; shift 2;; *) shift;; esac
    done
    case "${filter:-}" in
      label=com.docker.compose.project=*)
        wanted=${filter#label=com.docker.compose.project=}
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          if [ "$(lookup_label project "$line")" = "$wanted" ]; then
            lookup_label name "$line"
          fi
        done <"$state/containers"
        ;;
    esac
    ;;
  inspect)
    fail_for container-inspect-error
    [ "${1:-}" = -f ] && shift 2
    id=${1:-}
    line=$(grep "^$id|" "$state/containers" 2>/dev/null || true); [ -n "$line" ] || exit 1
    printf '/%s|%s|%s\n' "$(lookup_label name "$line")" "$(lookup_label project "$line")" "$(lookup_label stack "$line")"
    ;;
  network)
    sub=${1:-}; shift || :
    case "$sub" in
      ls)
        fail_for network-list-error
        while [ "$#" -gt 0 ]; do case "$1" in --filter) filter=$2; shift 2;; *) shift;; esac; done
        while IFS='|' read -r name owner stack; do
          [ -n "${name:-}" ] || continue
          case "${filter:-}" in
            label=com.docker.compose.project=*)
              if [ "$owner" = "${filter#label=com.docker.compose.project=}" ]; then printf '%s\n' "$name"; fi
              ;;
            name=^*'$'* )
              pattern=${filter#name=^}; pattern=${pattern%\$}
              if [ "$name" = "$pattern" ]; then printf '%s\n' "$name"; fi
              ;;
          esac
        done <"$state/networks"
        ;;
      inspect)
        fail_for network-inspect-error
        [ "${1:-}" = -f ] && shift 2
        name=${1:-}; line=$(grep "^$name|" "$state/networks" 2>/dev/null || true); [ -n "$line" ] || exit 1
        printf '%s|%s|%s\n' "$(lookup_label name "$line")" "$(lookup_label project "$line")" "$(lookup_label stack "$line")"
        ;;
      *) exit 2;;
    esac
    ;;
  volume)
    sub=${1:-}; shift || :
    case "$sub" in
      ls)
        fail_for volume-list-error
        while [ "$#" -gt 0 ]; do case "$1" in --filter) filter=$2; shift 2;; *) shift;; esac; done
        while IFS='|' read -r name owner stack; do
          [ -n "${name:-}" ] || continue
          case "${filter:-}" in
            label=com.docker.compose.project=*)
              if [ "$owner" = "${filter#label=com.docker.compose.project=}" ]; then printf '%s\n' "$name"; fi
              ;;
            name=^*'$'*)
              pattern=${filter#name=^}; pattern=${pattern%\$}
              if [ "$name" = "$pattern" ]; then printf '%s\n' "$name"; fi
              ;;
          esac
        done <"$state/volumes"
        ;;
      inspect)
        fail_for volume-inspect-error
        [ "${1:-}" = -f ] && shift 2
        name=${1:-}; line=$(grep "^$name|" "$state/volumes" 2>/dev/null || true); [ -n "$line" ] || exit 1
        printf '%s|%s|%s\n' "$(lookup_label name "$line")" "$(lookup_label project "$line")" "$(lookup_label stack "$line")"
        ;;
      rm)
        fail_for volume-rm-error
        name=${1:-}; grep -v "^$name|" "$state/volumes" >"$state/volumes.next" || :; mv "$state/volumes.next" "$state/volumes" ;;
      *) exit 2;;
    esac
    ;;
  image)
    sub=${1:-}; shift || :
    case "$sub" in
      ls)
        fail_for image-list-error
        while [ "$#" -gt 0 ]; do case "$1" in --filter) filter=$2; shift 2;; *) shift;; esac; done
        ref=${filter#reference=}; grep -Fx "$ref" "$state/images" 2>/dev/null || :
        ;;
      inspect)
        fail_for image-inspect-error
        [ "${1:-}" = -f ] && shift 2
        name=${1:-}; grep -Fx "$name" "$state/images" >/dev/null 2>&1 || exit 1
        printf '%s||\n' "$name"
        ;;
      rm)
        fail_for image-rm-error
        [ "${1:-}" = -f ] && shift
        name=${1:-}; grep -Fxv "$name" "$state/images" >"$state/images.next" || :; mv "$state/images.next" "$state/images" ;;
      *) exit 2;;
    esac
    ;;
  *) echo "unexpected fake Docker command: $cmd $*" >&2; exit 2;;
esac
EOF
chmod +x "$t/bin/docker"
project=agentotel-test
uuid=00000000-0000-4000-8000-000000000001
volumes="${project}_otelcol-queue ${project}_victorialogs-data ${project}_victoriametrics-data ${project}_victoriatraces-data"
run_case() {
  scenario=$1; expected=$2; runtime_mode=${3:-set}; shift 3
  : >"$t/state/containers"; : >"$t/state/networks"; : >"$t/state/volumes"; : >"$t/state/images"; : >"$t/state/calls"; rm -f "$t/state/down-called"
  printf '%s\n' "$@" >"$t/state/volumes"
  if [ "$scenario" = residual ] || [ "$scenario" = collision-container ]; then
    printf 'container-1|%s|%s\n' "$project" "$uuid" >"$t/state/containers"
    [ "$scenario" = residual ] && printf '%s-default|%s|%s\n' "$project" "$project" "$uuid" >"$t/state/networks"
  fi
  if [ "$scenario" = unset-dev ]; then
    printf '%s\n' \
      "dev-observability/app:dev" "dev-observability/gateway:dev" "dev-observability/dashboard:dev" \
      "dev-observability/victorialogs:v1.52.0-health-dev" "dev-observability/victoriametrics:v1.150.0-health-dev" \
      "dev-observability/victoriatraces:v0.11.0-health-dev" "dev-observability/otel-collector:v0.159.0-health-dev" >"$t/state/images"
  elif [ "$scenario" != not-found ]; then
    printf '%s\n' \
      "dev-observability/app:ci-test" "dev-observability/gateway:ci-test" "dev-observability/dashboard:ci-test" \
      "dev-observability/victorialogs:v1.52.0-health-ci-test" "dev-observability/victoriametrics:v1.150.0-health-ci-test" \
      "dev-observability/victoriatraces:v0.11.0-health-ci-test" "dev-observability/otel-collector:v0.159.0-health-ci-test" >"$t/state/images"
  fi
  set +e
  if [ "$runtime_mode" = unset ]; then
    env -u AGENTOTEL_RUNTIME_VERSION FAKE_DOCKER_STATE="$t/state" FAKE_DOCKER_SCENARIO="$scenario" PATH="$t/bin:$PATH" \
      COMPOSE_PROJECT_NAME="$project" AGENTOTEL_STACK_UUID="$uuid" GATEWAY_INGEST_TOKEN=cleanup-ingest GATEWAY_QUERY_TOKEN=cleanup-query \
      "$root/scripts/ci-supply-chain-cleanup.sh" >"$t/$scenario.out" 2>&1
    rc=$?
  else
    FAKE_DOCKER_STATE="$t/state" FAKE_DOCKER_SCENARIO="$scenario" PATH="$t/bin:$PATH" \
      COMPOSE_PROJECT_NAME="$project" AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_RUNTIME_VERSION=ci-test GATEWAY_INGEST_TOKEN=cleanup-ingest GATEWAY_QUERY_TOKEN=cleanup-query \
      "$root/scripts/ci-supply-chain-cleanup.sh" >"$t/$scenario.out" 2>&1
    rc=$?
  fi
  set -e
  if [ "$scenario" = success ] || [ "$scenario" = unset-dev ] || [ "$scenario" = not-found ]; then
    [ "$rc" -eq 0 ] || { echo "$scenario failed unexpectedly" >&2; sed -n '1,120p' "$t/$scenario.out" >&2; exit 1; }
  else
    [ "$rc" -ne 0 ] || { echo "$scenario unexpectedly passed" >&2; exit 1; }
  fi
  grep -Fq "$expected" "$t/$scenario.out" || { echo "$scenario missing evidence: $expected" >&2; sed -n '1,120p' "$t/$scenario.out" >&2; exit 1; }
  if [ "$scenario" = collision-container ]; then
    test ! -e "$t/state/down-called" || { echo 'collision preflight called Compose down' >&2; exit 1; }
  fi
}
set --
for volume in $volumes; do set -- "$@" "$volume|$project|$uuid"; done
run_case success 'cleanup: PASS' set "$@"
run_case unset-dev 'cleanup: PASS' unset "$@"
run_case not-found 'cleanup: PASS' set
run_case collision-container 'mismatched stack label' set \
  "${project}_otelcol-queue|$project|$uuid" \
  "${project}_victorialogs-data|$project|$uuid" \
  "${project}_victoriametrics-data|$project|$uuid" \
  "${project}_victoriatraces-data|$project|00000000-0000-4000-8000-000000000099"
run_case down-error 'Compose down failed' set "$@"
run_case volume-rm-error 'failed to remove owned volume' set "$@"
run_case image-rm-error 'failed to remove exact run image' set "$@"
run_case residual 'run-owned containers remain' set "$@"
run_case volume-list-error 'Docker volume listing operation failed' set "$@"
run_case container-list-error 'Docker container listing operation failed' set "$@"
run_case network-list-error 'Docker network listing operation failed' set "$@"
run_case image-list-error 'Docker image lookup' set "$@"
if grep -Eq 'docker (system|volume) prune|down[^\n]* -v|docker volume rm -f? \*' "$root/scripts/ci-supply-chain-cleanup.sh"; then
  echo 'cleanup helper contains a broad prune or wildcard deletion' >&2
  exit 1
fi
test -f "$t/state/down-called"
# A successful preflight must reach the exact Compose teardown command. The
# collision case above separately proves that this command is not reached when
# ownership labels do not match.
grep -Eq '^compose .* down --remove-orphans$' "$t/state/calls" || {
  echo 'cleanup fixture did not observe the exact Compose down command' >&2
  exit 1
}
echo 'CI supply-chain cleanup fixture: PASS (not-found, operational errors, collision preflight, dev images, exact cleanup, and residual assertions)'
