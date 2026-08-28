#!/bin/sh
# Exercise exact CI ownership/cleanup behavior with a fake Docker CLI.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/state"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_DOCKER_STATE:?}
scenario=${FAKE_DOCKER_SCENARIO:?}
cmd=${1:-}; shift || :
case "$cmd" in
  ps)
    if [ "$scenario" = preexisting-project ] || [ "$scenario" = post-cleanup-zero ]; then printf 'container-id\n'; fi
    ;;
  network)
    sub=${1:-}; shift || :
    case "$sub" in
      ls)
        if [ "$scenario" = preexisting-project ]; then printf 'network-id\n'; fi
        ;;
      inspect)
        name=${1:-}
        if [ "$scenario" = preexisting-project ] && [ "$name" = "agentotel-test_default" ]; then exit 0; fi
        exit 1
        ;;
    esac
    ;;
  volume)
    sub=${1:-}; shift || :
    case "$sub" in
      inspect)
        format=
        if [ "${1:-}" = -f ]; then format=$2; shift 2; fi
        name=${1:-}
        line=$(grep "^$name|" "$state/volumes" 2>/dev/null || true)
        [ -n "$line" ] || exit 1
        if [ -n "$format" ]; then
          oldIFS=$IFS; IFS='|'; set -- $line; IFS=$oldIFS
          printf '%s|%s|%s\n' "$1" "$2" "$3"
        fi
        ;;
      rm)
        name=${1:-}
        if [ "$scenario" = rm-failure ]; then exit 1; fi
        if [ "$scenario" = post-cleanup-zero ]; then exit 0; fi
        grep -v -F "^$name|" "$state/volumes" >"$state/volumes.next" || :
        mv "$state/volumes.next" "$state/volumes"
        ;;
    esac
    ;;
  *)
    echo "unexpected fake docker command: $cmd $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp/bin/docker"
cat >"$tmp/harness.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${ROOT:?}
. "$ROOT/scripts/ci-resource-guard.sh"
project=agentotel-test
uuid=00000000-0000-4000-8000-000000000001
volumes=(agentotel-test_otelcol-queue agentotel-test_victorialogs-data)
networks=(agentotel-test_default agentotel-test_edge)
ci_xdg_root=$(mktemp -d)
setup_attempted=0
compose_attempted=0
ci_failed=0
compose_raw() {
  if [[ "${1:-}" == --profile ]]; then
    while (($#)); do
      [[ "$1" == down ]] && break
      shift
    done
  fi
  if [[ "${FAKE_DOCKER_SCENARIO:-}" == down-failure ]]; then return 1; fi
  return 0
}
case "$FAKE_DOCKER_SCENARIO" in
  preexisting-project)
    ci_resource_inventory_preflight
    ;;
  mismatched-labels|rm-failure|post-cleanup-zero)
    setup_attempted=1
    compose_attempted=0
    ci_resource_cleanup
    ;;
  setup-before-create-failure)
    setup_attempted=1
    compose_attempted=0
    set +e
    false
    ci_resource_cleanup
    ;;
  down-failure)
    setup_attempted=0
    compose_attempted=1
    ci_resource_cleanup
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/harness.sh"

run_expect_fail() {
  scenario=$1; expected=$2
  shift 2
  : >"$tmp/state/volumes"
  printf '%s\n' "$@" >"$tmp/state/volumes"
  if FAKE_DOCKER_STATE="$tmp/state" FAKE_DOCKER_SCENARIO="$scenario" ROOT="$root" PATH="$tmp/bin:$PATH" \
    "$tmp/harness.sh" >"$tmp/$scenario.out" 2>&1; then
    echo "$scenario unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$scenario.out" || {
    echo "$scenario did not surface expected evidence: $expected" >&2
    cat "$tmp/$scenario.out" >&2
    exit 1
  }
}

run_expect_fail preexisting-project 'already owns containers'
run_expect_fail mismatched-labels 'mismatched ownership labels' \
  'agentotel-test_otelcol-queue|00000000-0000-4000-8000-000000000099|agentotel-test'
run_expect_fail setup-before-create-failure 'preserving original test failure status=1'
run_expect_fail down-failure 'Compose down failed'
run_expect_fail rm-failure 'failed to remove owned volume' \
  'agentotel-test_otelcol-queue|00000000-0000-4000-8000-000000000001|agentotel-test'
run_expect_fail post-cleanup-zero 'containers remain'

echo 'CI fake-Docker cleanup contract: PASS (preexisting refusal, ownership checks, setup/down/rm failures, and zero assertion)'
