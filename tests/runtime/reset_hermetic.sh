#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/state" "$t/config" "$t/run" "$t/compose"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_DOCKER_STATE:?}; mode=${FAKE_DOCKER_MODE:-ok}; sub=${1:-}
if [ "$sub" = compose ]; then
  shift; [ "${1:-}" = -p ] && shift 2
  case "${1:-}" in config) [ "$mode" != stop-failure ];;
    down) [ "$mode" != stop-failure ] || exit 1; echo compose-down >>"$state/log";; esac; exit 0
fi
if [ "$sub" = volume ]; then
  shift; op=${1:-}; shift; template=''; [ "${1:-}" = -f ] && { template=$2; shift 2; }; name=${1:-};
  case "$op" in inspect)
    [ -f "$state/$name" ] || exit 1
    case "$template" in *com.agentotel.stack*) cut -d'|' -f1 "$state/$name";; *com.docker.compose.project*) cut -d'|' -f2 "$state/$name";; *) cat "$state/$name";; esac;;
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
vols='otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data grafana-data'
run_case() {
  mode=$1; answer=$2; expect=$3; label=$4
  find "$t/state" -type f -delete; mkdir -p "$t/state/agentotel"; uuid=11111111-1111-1111-1111-111111111111; printf '%s\n' "$uuid" >"$t/state/agentotel/stack.uuid"
  for v in $vols; do printf '%s|dev-observability\n' "$label" >"$t/state/dev-observability_$v"; done
  printf 'unrelated|other\n' >"$t/state/unrelated_volume"
  set +e; RESET_ANSWER=$answer FAKE_DOCKER_MODE=$mode FAKE_DOCKER_STATE=$t/state PATH=$t/bin:$PATH HOME=$t/home XDG_STATE_HOME=$t/state XDG_CONFIG_HOME=$t/config XDG_RUNTIME_DIR=$t/run COMPOSE_PROJECT_NAME=dev-observability python3 "$t/driver.py" "$root/bin/obs" reset --all --confirm >"$t/out" 2>&1; rc=$?; set -e
  [ "$rc" -eq "$expect" ] || { echo "FAIL $mode rc=$rc"; cat "$t/out"; exit 1; }
  if [ "$expect" -eq 0 ]; then [ -s "$t/state/removed" ] || { echo "FAIL $mode no removals"; exit 1; }; [ -f "$t/state/unrelated_volume" ] || { echo "FAIL $mode unrelated removed"; exit 1; }; else [ ! -e "$t/state/removed" ] || { echo "FAIL $mode deleted volumes"; exit 1; }; fi
}
run_case ok 11111111-1111-1111-1111-111111111111 0 11111111-1111-1111-1111-111111111111
run_case ok wrong 2 11111111-1111-1111-1111-111111111111
run_case ok 11111111-1111-1111-1111-111111111111 2 wrong-label
run_case in-use 11111111-1111-1111-1111-111111111111 2 11111111-1111-1111-1111-111111111111
run_case stop-failure 11111111-1111-1111-1111-111111111111 2 11111111-1111-1111-1111-111111111111
set +e; FAKE_DOCKER_MODE=ok FAKE_DOCKER_STATE=$t/state PATH=$t/bin:$PATH HOME=$t/home XDG_STATE_HOME=$t/state XDG_CONFIG_HOME=$t/config XDG_RUNTIME_DIR=$t/run "$root/bin/obs" reset --all --confirm </dev/null >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || { echo 'FAIL nonTTY'; exit 1; }
echo 'reset hermetic checks passed (positive + 5 refusal cases)'
