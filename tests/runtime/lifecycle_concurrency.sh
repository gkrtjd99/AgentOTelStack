#!/usr/bin/env bash
# Setup/reset share one lifecycle lock and cannot overlap Docker lifecycle work.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/config/agentotel" "$t/data" "$t/state/agentotel" "$t/run" "$t/volumes"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}' >"$t/config/agentotel/credentials"
chmod 600 "$t/config/agentotel/credentials"
uuid=11111111-1111-4111-1111-111111111111
printf '%s\n' "$uuid" >"$t/state/agentotel/stack.uuid"

cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_STATE:?}
volumes="$state/volumes"
log="$state/docker.log"
mkdir -p "$volumes"
printf '%s\n' "$*" >>"$log"
sub=${1:-}; shift || :
if [ "$sub" = volume ]; then
  op=${1:-}; shift || :
  case "$op" in
    ls)
      : >"$state/setup-inventory-start"
      while [ ! -e "$state/release-inventory" ]; do sleep .01; done
      for file in "$volumes"/*; do [ -f "$file" ] || continue; basename "$file"; done
      ;;
    inspect)
      template=''; names=''; skip=0
      for arg do
        if [ "$skip" -eq 1 ]; then template=$arg; skip=0; continue; fi
        case "$arg" in
          -f|--format) skip=1;;
          '{{*') template=$arg;;
          *_otelcol-queue|*_victorialogs-data|*_victoriametrics-data|*_victoriatraces-data)
            names="${names}${arg}
";;
        esac
      done
      old_ifs=$IFS; IFS='
'
      for name in $names; do
        [ -n "$name" ] || continue
        [ -f "$volumes/$name" ] || exit 1
        IFS='|' read -r stack project <"$volumes/$name"
        case "$template" in
          *'{{.Name}}'*com.agentotel.stack*) printf '%s|%s|%s\n' "$name" "$stack" "$project";;
          *com.agentotel.stack*com.docker.compose.project*) printf '%s|%s\n' "$stack" "$project";;
          *com.agentotel.stack*) printf '%s\n' "$stack";;
          *com.docker.compose.project*) printf '%s\n' "$project";;
          *) printf '{}\n';;
        esac
      done
      IFS=$old_ifs
      ;;
    create)
      stack=''; project=''; name=''; skip=0
      for arg do
        if [ "$skip" -eq 1 ]; then
          case "$arg" in
            com.agentotel.stack=*) stack=${arg#*=};;
            com.docker.compose.project=*) project=${arg#*=};;
          esac
          skip=0; continue
        fi
        case "$arg" in --label) skip=1;; *_otelcol-queue|*_victorialogs-data|*_victoriametrics-data|*_victoriatraces-data) name=$arg;; esac
      done
      printf '%s|%s\n' "$stack" "$project" >"$volumes/$name"
      printf '%s\n' "$name"
      ;;
    rm)
      name=${1:-}; rm -f "$volumes/$name"; printf 'removed %s\n' "$name" >>"$log";
      ;;
    *) exit 90;;
  esac
  exit 0
fi
if [ "$sub" = compose ]; then
  [ "${GATEWAY_INGEST_TOKEN:-}" = aaaaaaaa ]
  [ "${GATEWAY_QUERY_TOKEN:-}" = bbbbbbbb ]
  [ "${1:-}" = -p ] && shift 2
  case "${1:-}" in
    config) printf 'compose-config\n' >>"$log";;
    up)
      : >"$state/compose-up-start"
      while [ ! -e "$state/release-compose-up" ]; do sleep .01; done
      printf 'compose-up\n' >>"$log"
      ;;
    down) printf 'compose-down\n' >>"$log";;
  esac
  exit 0
fi
if [ "$sub" = ps ]; then exit 0; fi
exit 90
EOF
chmod 755 "$t/bin/docker"

cat >"$t/driver.py" <<'EOF'
import os, pty, subprocess, sys
master, slave = pty.openpty()
env = os.environ.copy()
proc = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, env=env)
os.write(master, (env.get('RESET_ANSWER', '') + '\n').encode())
proc.wait()
try:
    output = os.read(master, 65536)
except OSError:
    output = b''
print(output.decode(errors='replace'), end='')
raise SystemExit(proc.returncode)
EOF
chmod 755 "$t/driver.py"

common_env=(
  "HOME=$t/home"
  "XDG_CONFIG_HOME=$t/config"
  "XDG_DATA_HOME=$t/data"
  "XDG_STATE_HOME=$t/state"
  "XDG_RUNTIME_DIR=$t/run"
  COMPOSE_PROJECT_NAME=overlap-stack
  "FAKE_STATE=$t"
  AGENTOTEL_DEV_MODE=1
)
env PATH="$t/bin:$PATH" "${common_env[@]}" "$root/bin/obs" up >"$t/setup.out" 2>"$t/setup.err" & setup_pid=$!
for _ in $(seq 1 100); do [ -e "$t/setup-inventory-start" ] && break; sleep .05; done
[ -e "$t/setup-inventory-start" ] || { echo 'setup did not reach locked inventory phase' >&2; exit 1; }
env PATH="$t/bin:$PATH" "${common_env[@]}" RESET_ANSWER="$uuid" python3 "$t/driver.py" "$root/bin/obs" reset --all --confirm >"$t/reset.out" 2>&1 & reset_pid=$!
sleep .1
! grep -q 'compose-down' "$t/docker.log" 2>/dev/null || { echo 'reset entered Compose while setup held lifecycle lock' >&2; exit 1; }
: >"$t/release-inventory"
for _ in $(seq 1 100); do [ -e "$t/compose-up-start" ] && break; sleep .05; done
[ -e "$t/compose-up-start" ] || { echo 'setup did not reach Compose up while holding lifecycle lock' >&2; exit 1; }
sleep .1
! grep -q 'compose-down' "$t/docker.log" 2>/dev/null || { echo 'reset entered Compose while setup up held lifecycle lock' >&2; exit 1; }
: >"$t/release-compose-up"
wait "$setup_pid"
wait "$reset_pid"

[ "$(grep -c '^compose-down$' "$t/docker.log")" -eq 1 ]
create_line=$(grep -n 'volume create' "$t/docker.log" | tail -1 | cut -d: -f1)
down_line=$(grep -n '^compose-down$' "$t/docker.log" | cut -d: -f1)
[ "$create_line" -lt "$down_line" ]
for suffix in otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data; do
  [ ! -e "$t/volumes/overlap-stack_$suffix" ] || { echo "volume survived reset: $suffix" >&2; exit 1; }
done

# Reset/reset is also serialized: exactly one reset owns the four resources;
# the waiter observes a complete post-reset empty inventory and cannot remove
# anything twice.
: >"$t/docker.log"
rm -f "$t/state/agentotel/lifecycle.lock" "$t/state/agentotel/lifecycle.lock/owner"
for suffix in otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data; do
  printf '%s|overlap-stack\n' "$uuid" >"$t/volumes/overlap-stack_$suffix"
done
set +e
env PATH="$t/bin:$PATH" "${common_env[@]}" RESET_ANSWER="$uuid" python3 "$t/driver.py" "$root/bin/obs" reset --all --confirm >"$t/reset-one.out" 2>&1 & reset_one=$!
env PATH="$t/bin:$PATH" "${common_env[@]}" RESET_ANSWER="$uuid" python3 "$t/driver.py" "$root/bin/obs" reset --all --confirm >"$t/reset-two.out" 2>&1 & reset_two=$!
wait "$reset_one"; rc_one=$?
wait "$reset_two"; rc_two=$?
set -e
successes=0
[ "$rc_one" -eq 0 ] && successes=$((successes + 1))
[ "$rc_two" -eq 0 ] && successes=$((successes + 1))
[ "$successes" -eq 1 ] || { echo "reset/reset expected one success (rc=$rc_one,$rc_two)" >&2; exit 1; }
[ "$(grep -c '^compose-down$' "$t/docker.log")" -eq 1 ] || { echo 'reset/reset ran Compose down more than once' >&2; exit 1; }
[ "$(grep -c '^removed ' "$t/docker.log")" -eq 4 ] || { echo 'reset/reset removed a non-canonical or duplicate volume' >&2; exit 1; }
[ ! -e "$t/state/agentotel/lifecycle.lock" ] || { echo 'reset/reset left lifecycle lock' >&2; exit 1; }
for suffix in otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data; do
  [ ! -e "$t/volumes/overlap-stack_$suffix" ] || { echo "reset/reset left volume: $suffix" >&2; exit 1; }
done
printf '%s\n' 'setup/reset/reset lifecycle serialization passed (no duplicate down or removal)'
