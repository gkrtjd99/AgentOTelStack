#!/bin/sh
# Hermetic contract checks for the live integration port selector.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
holder=
default_holder=
default_owned=0
cleanup() {
  if [ -n "$holder" ]; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
  fi
  if [ -n "$default_holder" ] && [ "$default_owned" -eq 1 ]; then
    kill "$default_holder" 2>/dev/null || true
    wait "$default_holder" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
uuid=00000000-0000-4000-8000-000000000001
project=00000000-0000-4000-8000-000000000002

if env AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID=00000000-0000-1000-8000-000000000002 CI_PORT_SELECTION_SELF_TEST=1 \
  bash "$root/scripts/test-ci-integration.sh" >"$tmp/project-v1.out" 2>&1; then
  echo 'UUIDv1 project ID was accepted' >&2
  exit 1
fi
grep -Fq 'must be UUIDv4' "$tmp/project-v1.out"

if ! output=$(env \
  AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project" \
  CI_PORT_SELECTION_SELF_TEST=1 \
  GATEWAY_INGEST_HOST_PORT= GATEWAY_QUERY_HOST_PORT= APP_HOST_PORT= \
  DASHBOARD_HOST_PORT= \
  bash "$root/scripts/test-ci-integration.sh"); then
  echo 'automatic port selection self-test failed' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq 'PORT_SELECTION_SELF_TEST=pass'
OUTPUT="$output" python3 - <<'PY'
import os
import re

match = re.search(
    r"PORT_SELECTION_SELF_TEST=pass ingest=(\d+) query=(\d+) app=(\d+) dashboard=(\d+)",
    os.environ["OUTPUT"],
)
if not match:
    raise SystemExit("port selection output has no complete result")
ports = [int(value) for value in match.groups()]
if len(set(ports)) != len(ports):
    raise SystemExit(f"automatic ports collide: {ports}")
if any(port < 1024 or port > 65535 for port in ports):
    raise SystemExit(f"automatic port out of range: {ports}")
PY

if env \
  AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project" \
  CI_PORT_SELECTION_SELF_TEST=1 \
  GATEWAY_INGEST_HOST_PORT=45123 GATEWAY_QUERY_HOST_PORT=45123 \
  APP_HOST_PORT= DASHBOARD_HOST_PORT= \
  bash "$root/scripts/test-ci-integration.sh" >"$tmp/duplicate.out" 2>&1; then
  echo 'duplicate explicit ports were accepted' >&2
  exit 1
fi
grep -Fq 'duplicates another explicitly selected host port' "$tmp/duplicate.out"

if env \
  AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project" \
  CI_PORT_SELECTION_SELF_TEST=1 \
  GATEWAY_INGEST_HOST_PORT=01024 GATEWAY_QUERY_HOST_PORT= APP_HOST_PORT= DASHBOARD_HOST_PORT= \
  bash "$root/scripts/test-ci-integration.sh" >"$tmp/leading-zero.out" 2>&1; then
  echo 'leading-zero explicit port was accepted' >&2
  exit 1
fi
grep -Fq 'leading zeros are rejected' "$tmp/leading-zero.out"

for boundary in 1024 65535; do
  if ! boundary_output=$(env \
    AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project" \
    CI_PORT_SELECTION_SELF_TEST=1 \
    GATEWAY_INGEST_HOST_PORT="$boundary" GATEWAY_QUERY_HOST_PORT= APP_HOST_PORT= DASHBOARD_HOST_PORT= \
    bash "$root/scripts/test-ci-integration.sh" 2>&1); then
    echo "valid boundary port $boundary was rejected; output=$boundary_output" >&2
    exit 1
  fi
done

# Make-managed E2E must not fall back to the historical app default (3000).
# Occupy that default and exercise the actual run-e2e selector before Docker.
python3 - <<'PY' "$tmp/default.ready" &
import socket, sys, time
s = socket.socket()
try:
    s.bind(("127.0.0.1", 3000))
    s.listen(1)
    with open(sys.argv[1], "w") as f:
        f.write("owned\\n")
        f.flush()
    time.sleep(30)
except OSError:
    with open(sys.argv[1], "w") as f:
        f.write("occupied\\n")
PY
default_holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/default.ready" ] && break; sleep .05; done
[ -s "$tmp/default.ready" ] || { echo 'default-port holder did not initialize' >&2; exit 1; }
if grep -Fqx owned "$tmp/default.ready"; then default_owned=1; fi
if ! default_output=$(env \
  AGENTOTEL_DEV_MODE=1 E2E_PORT_SELECTION_SELF_TEST=1 \
  HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
  XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" \
  GATEWAY_INGEST_HOST_PORT= GATEWAY_QUERY_HOST_PORT= APP_HOST_PORT= DASHBOARD_HOST_PORT= \
  make -C "$root" e2e-app 2>&1); then
  echo 'Make-managed E2E dynamic port self-test failed with occupied default port' >&2
  printf '%s\n' "$default_output" >&2
  exit 1
fi
printf '%s\n' "$default_output" | grep -Fq 'E2E_PORT_SELECTION_SELF_TEST=pass'
if grep -Fqx owned "$tmp/default.ready" || ! python3 - <<'PY'
import socket
s = socket.socket()
try:
    s.bind(("127.0.0.1", 3000))
except OSError:
    raise SystemExit(0)
else:
    s.close()
    raise SystemExit(1)
PY
then
  default_app=$(printf '%s\n' "$default_output" | sed -n 's/.* app=\([0-9][0-9]*\) dashboard=.*/\1/p')
  if [ -z "$default_app" ] || [ "$default_app" -eq 3000 ]; then
    echo 'E2E selected occupied historical app default' >&2
    exit 1
  fi
fi

# Hold a real loopback socket so the explicit-unavailable path is deterministic.
python3 - "$tmp/reserved.port" <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]) + "\n")
    f.flush()
time.sleep(30)
PY
holder=$!
for _ in 1 2 3 4 5; do [ -s "$tmp/reserved.port" ] && break; sleep 1; done
if [ ! -s "$tmp/reserved.port" ]; then
  kill "$holder" 2>/dev/null || true
  echo 'could not reserve a loopback port for unavailable-port test' >&2
  exit 1
fi
read -r unavailable_port < "$tmp/reserved.port"
if env \
  AGENTOTEL_STACK_UUID="$uuid" AGENTOTEL_PROJECT_ID="$project" \
  CI_PORT_SELECTION_SELF_TEST=1 \
  GATEWAY_INGEST_HOST_PORT="$unavailable_port" GATEWAY_QUERY_HOST_PORT= APP_HOST_PORT= DASHBOARD_HOST_PORT= \
  bash "$root/scripts/test-ci-integration.sh" >"$tmp/unavailable.out" 2>&1; then
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  echo 'unavailable explicit port was accepted' >&2
  exit 1
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -Fq 'is unavailable on loopback' "$tmp/unavailable.out"

echo 'CI port selection contract: PASS (unique automatic ports; duplicate and unavailable explicit ports rejected)'
