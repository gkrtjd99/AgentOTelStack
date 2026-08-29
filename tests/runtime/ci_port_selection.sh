#!/bin/sh
# Hermetic contract checks for the shared loopback port selector. These tests
# source the selector library directly; they never use a lifecycle success
# bypass or pretend that Compose/browser services were started.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-port-selection.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
uuid=00000000-0000-4000-8000-000000000001

# The dollar signs are intentionally evaluated by the inner bash -c script.
# shellcheck disable=SC2016
selector='set -Eeuo pipefail
. "$1/scripts/port-selection.sh"
port_selection_select
printf "ports=%s,%s,%s,%s urls=%s,%s,%s\n" \
  "$GATEWAY_INGEST_HOST_PORT" "$GATEWAY_QUERY_HOST_PORT" "$APP_HOST_PORT" "$DASHBOARD_HOST_PORT" \
  "$GATEWAY_URL" "$APP_URL" "$DASHBOARD_URL"'

if ! output=$(env \
  requested_gateway_ingest_port= requested_gateway_query_port= \
  requested_app_port= requested_dashboard_port= \
  bash -c "$selector" bash "$root"); then
  echo 'automatic port selection failed' >&2
  exit 1
fi
OUTPUT="$output" python3 - <<'PY'
import os
import re

match = re.search(r"ports=([0-9]+),([0-9]+),([0-9]+),([0-9]+) urls=(.*)", os.environ["OUTPUT"])
if not match:
    raise SystemExit("automatic selector output has no complete result")
ports = [int(value) for value in match.groups()[:4]]
if len(set(ports)) != len(ports):
    raise SystemExit(f"automatic ports collide: {ports}")
if any(port < 1024 or port > 65535 for port in ports):
    raise SystemExit(f"automatic port out of range: {ports}")
if match.group(5) != f"http://127.0.0.1:{ports[1]},http://127.0.0.1:{ports[2]},http://127.0.0.1:{ports[3]}":
    raise SystemExit("selector URLs do not follow selected ports")
PY

# Validation-only boundary cases do not bind well-known ports, so they remain
# deterministic even on a host with another service already listening.
for boundary in 1024 65535; do
  # $1 is intentionally expanded by the inner bash -c script.
  # shellcheck disable=SC2016
  env requested_gateway_ingest_port="$boundary" requested_gateway_query_port= \
    requested_app_port= requested_dashboard_port= \
    bash -c '. "$1/scripts/port-selection.sh"; port_selection_validate_requested' bash "$root"
done

# $1 is intentionally expanded by the inner bash -c script.
# shellcheck disable=SC2016
if env requested_gateway_ingest_port=45123 requested_gateway_query_port=45123 \
  requested_app_port= requested_dashboard_port= \
  bash -c '. "$1/scripts/port-selection.sh"; port_selection_validate_requested' bash "$root" >"$tmp/duplicate.out" 2>&1; then
  echo 'duplicate explicit ports were accepted' >&2
  exit 1
fi
grep -Fq 'duplicates another explicitly selected host port' "$tmp/duplicate.out"

# $1 is intentionally expanded by the inner bash -c script.
# shellcheck disable=SC2016
if env requested_gateway_ingest_port=01024 requested_gateway_query_port= \
  requested_app_port= requested_dashboard_port= \
  bash -c '. "$1/scripts/port-selection.sh"; port_selection_validate_requested' bash "$root" >"$tmp/leading-zero.out" 2>&1; then
  echo 'leading-zero explicit port was accepted' >&2
  exit 1
fi
grep -Fq 'leading zeros are rejected' "$tmp/leading-zero.out"

for invalid in 1023 65536 abc; do
  # $1 is intentionally expanded by the inner bash -c script.
  # shellcheck disable=SC2016
  if env requested_gateway_ingest_port="$invalid" requested_gateway_query_port= \
    requested_app_port= requested_dashboard_port= \
    bash -c '. "$1/scripts/port-selection.sh"; port_selection_validate_requested' bash "$root" >"$tmp/invalid.out" 2>&1; then
    echo "invalid explicit port $invalid was accepted" >&2
    exit 1
  fi
done

# Hold a real loopback socket so the explicit-unavailable path is deterministic.
python3 - "$tmp/reserved.port" <<'PY' &
import socket
import sys
import time

s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(s.getsockname()[1]) + "\n")
    handle.flush()
time.sleep(30)
PY
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$tmp/reserved.port" ] && break
  sleep .05
done
[ -s "$tmp/reserved.port" ] || { echo 'could not reserve a loopback port' >&2; exit 1; }
read -r unavailable_port <"$tmp/reserved.port"
if env requested_gateway_ingest_port="$unavailable_port" requested_gateway_query_port= \
  requested_app_port= requested_dashboard_port= \
  bash -c "$selector" bash "$root" >"$tmp/unavailable.out" 2>&1; then
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  echo 'unavailable explicit port was accepted' >&2
  exit 1
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -Fq 'is unavailable on loopback' "$tmp/unavailable.out"

# The old lifecycle environment variables must not turn either runner into a
# successful selector-only command. Invalid input must still reach the library.
if env \
  AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID=00000000-0000-1000-8000-000000000002 \
  CI_PORT_SELECTION_SELF_TEST=1 GATEWAY_INGEST_HOST_PORT=1 \
  HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
  XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" \
  bash "$root/scripts/test-ci-integration.sh" >"$tmp/ci-bypass.out" 2>&1; then
  echo 'CI port-selection marker bypassed invalid lifecycle input' >&2
  exit 1
fi
grep -Fq 'must be UUIDv4' "$tmp/ci-bypass.out"

if env \
  E2E_PORT_SELECTION_SELF_TEST=1 APP_HOST_PORT=1 \
  HOME="$tmp/home-e2e" XDG_CONFIG_HOME="$tmp/config-e2e" XDG_DATA_HOME="$tmp/data-e2e" \
  XDG_STATE_HOME="$tmp/state-e2e" XDG_RUNTIME_DIR="$tmp/run-e2e" \
  AGENTOTEL_DEV_MODE=1 bash "$root/scripts/run-e2e.sh" app >"$tmp/e2e-bypass.out" 2>&1; then
  echo 'E2E port-selection marker bypassed invalid lifecycle input' >&2
  exit 1
fi
grep -Fq 'must be a TCP port' "$tmp/e2e-bypass.out"

if grep -Fq 'E2E_PORT_SELECTION_SELF_TEST=pass' "$root/scripts/run-e2e.sh"; then
  exit 1
fi
if grep -Fq 'PORT_SELECTION_SELF_TEST=pass' "$root/scripts/test-ci-integration.sh"; then
  exit 1
fi

echo 'CI port selection contract: PASS (library selectors exercised; invalid, duplicate, unavailable, and bypass inputs rejected)'
