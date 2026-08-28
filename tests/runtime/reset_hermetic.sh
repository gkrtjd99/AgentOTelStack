#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
. "$root/libexec/agentotel/common.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/state" "$t/config" "$t/run" "$t/compose"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_DOCKER_STATE:?}; mode=${FAKE_DOCKER_MODE:-ok}; sub=${1:-}
if [ "$sub" = compose ]; then
  [ "${GATEWAY_INGEST_TOKEN:-}" = aaaaaaaa ]
  [ "${GATEWAY_QUERY_TOKEN:-}" = bbbbbbbb ]
  shift; [ "${1:-}" = -p ] && shift 2
  case "${1:-}" in
    config) exit 0 ;;
    down)
      [ "$mode" != stop-failure ] || exit 1
      echo compose-down >>"$state/log"
      : >"$state/down-complete"
      ;;
  esac
  exit 0
fi
if env | grep -Eq '^(GATEWAY_[^=]*|GF_[^=]*)='; then
  echo 'secrets escaped the Compose child boundary' >&2
  exit 1
fi
if [ "$sub" = volume ]; then
  shift; op=${1:-}; shift; template=''; [ "${1:-}" = -f ] && { template=$2; shift 2; }; name=${1:-};
  case "$op" in inspect)
    [ -f "$state/$name" ] || exit 1
    case "$template" in
      *com.agentotel.stack*com.docker.compose.project*)
        if [ "$mode" = swapped-label ] && [ -e "$state/down-complete" ]; then printf '%s|%s\n' swapped-stack swapped-project; else cat "$state/$name"; fi
        ;;
      *com.agentotel.stack*)
        if [ "$mode" = swapped-label ] && [ -e "$state/down-complete" ]; then printf '%s\n' swapped-stack; else cut -d'|' -f1 "$state/$name"; fi
        ;;
      *com.docker.compose.project*)
        if [ "$mode" = swapped-label ] && [ -e "$state/down-complete" ]; then printf '%s\n' swapped-project; else cut -d'|' -f2 "$state/$name"; fi
        ;;
      *) cat "$state/$name";;
    esac;;
    rm) echo "$name" >>"$state/removed"; rm -f "$state/$name";; esac; exit 0
fi
if [ "$sub" = ps ]; then [ "$mode" = in-use ] && echo unrelated-holder; exit 0; fi
exit 0
EOF
chmod 755 "$t/bin/docker"
cat >"$t/driver.py" <<'EOF'
import os, pty, subprocess, sys
env=os.environ.copy(); master,slave=pty.openpty(); p=subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, env=env)
os.write(master, (env.get('RESET_ANSWER','')+'\n').encode()); p.wait(); out=b''
try: out=os.read(master,65536)
except OSError: pass
print(out.decode(errors='replace'), end=''); raise SystemExit(p.wait())
EOF
chmod 755 "$t/driver.py"
mkdir -p "$t/config/agentotel"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}' >"$t/config/agentotel/credentials"
chmod 600 "$t/config/agentotel/credentials"
volume_fixture=$(agentotel_active_volume_names dev-observability)
run_case() {
  mode=$1; answer=$2; expect=$3; label=$4
  find "$t/state" -type f -delete; mkdir -p "$t/state/agentotel"; uuid=11111111-1111-1111-1111-111111111111; printf '%s\n' "$uuid" >"$t/state/agentotel/stack.uuid"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    printf '%s|dev-observability\n' "$label" >"$t/state/$v"
  done <<EOF
$volume_fixture
EOF
  # A pre-dashboard runtime's volume is migration state, not an active resource.
  printf 'legacy|dev-observability\n' >"$t/state/dev-observability_grafana-data"
  printf 'unrelated|other\n' >"$t/state/unrelated_volume"
  set +e; AGENTOTEL_DEV_MODE=1 RESET_ANSWER=$answer FAKE_DOCKER_MODE=$mode FAKE_DOCKER_STATE=$t/state PATH=$t/bin:$PATH HOME=$t/home XDG_STATE_HOME=$t/state XDG_CONFIG_HOME=$t/config XDG_RUNTIME_DIR=$t/run COMPOSE_PROJECT_NAME=dev-observability python3 "$t/driver.py" "$root/bin/obs" reset --all --confirm >"$t/out" 2>&1; rc=$?; set -e
  [ "$rc" -eq "$expect" ] || { echo "FAIL $mode rc=$rc"; cat "$t/out"; exit 1; }
  if [ "$expect" -ne 0 ]; then
    case "$mode:$answer:$label" in
      ok:wrong:*) grep -q 'UUID mismatch' "$t/out" ;;
      ok:*:wrong-label) grep -q 'volume identity mismatch' "$t/out" ;;
      in-use:*) grep -q 'volume is still in use' "$t/out" ;;
      stop-failure:*) grep -q 'stack stop/remove failed' "$t/out" ;;
      swapped-label:*) grep -q 'volume ownership changed before removal' "$t/out" ;;
    esac || { echo "FAIL $mode diagnostic did not identify the refusal"; cat "$t/out"; exit 1; }
  fi
  if [ "$expect" -eq 0 ]; then
    [ -s "$t/state/removed" ] || { echo "FAIL $mode no removals"; exit 1; }
    expected_removed=$(printf '%s\n' "$volume_fixture" | sort)
    actual_removed=$(sort "$t/state/removed")
    [ "$(wc -l <"$t/state/removed" | tr -d ' ')" -eq 4 ] || { echo "FAIL $mode removed count is not exactly four"; exit 1; }
    [ "$actual_removed" = "$expected_removed" ] || { echo "FAIL $mode removed set differs"; printf 'expected:\n%s\nactual:\n%s\n' "$expected_removed" "$actual_removed"; exit 1; }
    extra_active=$(find "$t/state" -maxdepth 1 -type f -name 'dev-observability_*' ! -name 'dev-observability_grafana-data' -print)
    [ -z "$extra_active" ] || { echo "FAIL $mode left extra canonical active volumes: $extra_active"; exit 1; }
    while IFS= read -r active; do
      [ -n "$active" ] || continue
      [ ! -e "$t/state/$active" ] || { echo "FAIL $mode active volume survived: $active"; exit 1; }
    done <<EOF_ACTIVE
$volume_fixture
EOF_ACTIVE
    [ -f "$t/state/unrelated_volume" ] || { echo "FAIL $mode unrelated removed"; exit 1; }
  else
    [ ! -e "$t/state/removed" ] || { echo "FAIL $mode deleted volumes"; exit 1; }
    while IFS= read -r active; do
      [ -n "$active" ] || continue
      [ -f "$t/state/$active" ] || { echo "FAIL $mode preserved volume missing: $active"; exit 1; }
    done <<EOF_ACTIVE
$volume_fixture
EOF_ACTIVE
  fi
  [ -f "$t/state/dev-observability_grafana-data" ] || { echo "FAIL $mode legacy volume removed"; exit 1; }
}
run_case ok 11111111-1111-1111-1111-111111111111 0 11111111-1111-1111-1111-111111111111
run_case ok wrong 2 11111111-1111-1111-1111-111111111111
run_case ok 11111111-1111-1111-1111-111111111111 2 wrong-label
run_case in-use 11111111-1111-1111-1111-111111111111 2 11111111-1111-1111-1111-111111111111
run_case stop-failure 11111111-1111-1111-1111-111111111111 2 11111111-1111-1111-1111-111111111111
run_case swapped-label 11111111-1111-1111-1111-111111111111 2 11111111-1111-1111-1111-111111111111
set +e; AGENTOTEL_DEV_MODE=1 FAKE_DOCKER_MODE=ok FAKE_DOCKER_STATE=$t/state PATH=$t/bin:$PATH HOME=$t/home XDG_STATE_HOME=$t/state XDG_CONFIG_HOME=$t/config XDG_RUNTIME_DIR=$t/run "$root/bin/obs" reset --all --confirm </dev/null >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || { echo 'FAIL nonTTY'; exit 1; }
echo 'reset hermetic checks passed (positive + 6 refusal cases; exact labels rechecked before every removal)'
