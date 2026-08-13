#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
mkdirs
REG="$STATE/runs"; LOCK="$REG.lock"; mkdir -p "$REG"; chmod 700 "$REG"
lock(){ i=0; while ! mkdir "$LOCK" 2>/dev/null; do i=$((i+1)); [ "$i" -lt 100 ] || die 'registry busy' 75; sleep .01; done; trap 'rmdir "$LOCK" 2>/dev/null || :' EXIT; }
unlock(){ rmdir "$LOCK" 2>/dev/null || :; trap - EXIT; }
sha(){
  for arg in "$@"; do
    printf '%s:' "${#arg}"
    printf '%s\n' "$arg"
  done | shasum -a 256 | awk '{print $1}'
}
proc_fp(){ ps -o command= -p "$1" 2>/dev/null | sed 's/^ *//' | shasum -a 256 | awk '{print $1}'; }
startid(){ ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//' || :; }
write_record(){
  lock
  (
    umask 077
    start=$(json_escape "$(startid "$2")")
    scope=$(json_escape "$6")
    scope_fp=$(sha "$6")
    printf '{"schema":1,"run_id":"%s","pid":%s,"pgid":%s,"isolated_process_group":%s,"process_start":"%s","argv_fingerprint":"%s","process_fingerprint":"%s","scope_fingerprint":"%s","scope":"%s"}\n' \
      "$1" "$2" "$3" "$4" "$start" "$5" "$(proc_fp "$2")" "$scope_fp" "$scope" >"$REG/$1.tmp.$$"
    chmod 600 "$REG/$1.tmp.$$"
    mv -f "$REG/$1.tmp.$$" "$REG/$1.json"
  )
  unlock
}
clear_record(){ lock; rm -f "$REG/$1.json"; unlock; }
valid_run_id(){ valid_uuid "$1"; }
record_for(){ id=$1; valid_run_id "$id" || die 'invalid run id' 69; f="$REG/$id.json"; [ -f "$f" ] || die 'run not found' 69; printf '%s\n' "$f"; }
verify_record(){
  f=$1; pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f"); pgid=$(sed -n 's/.*"pgid":\([0-9][0-9]*\).*/\1/p' "$f"); isolated=$(sed -n 's/.*"isolated_process_group":\(true\|false\).*/\1/p' "$f"); old=$(sed -n 's/.*"process_start":"\([^"]*\)".*/\1/p' "$f"); pf=$(sed -n 's/.*"process_fingerprint":"\([^"]*\)".*/\1/p' "$f")
  now=$(startid "$pid")
  if [ -z "$now" ] || [ "$now" != "$old" ]; then die 'stale or pid reuse' 69; fi
  [ "$(proc_fp "$pid")" = "$pf" ] || die 'process fingerprint mismatch' 69
  if [ "$isolated" = true ]; then [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pgid" ] || die 'pgid ownership mismatch' 69; fi
}
signal_record(){
  f=$1; verify_record "$f"; pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f"); pgid=$(sed -n 's/.*"pgid":\([0-9][0-9]*\).*/\1/p' "$f"); isolated=$(sed -n 's/.*"isolated_process_group":\(true\|false\).*/\1/p' "$f")
  if [ "$isolated" = true ]; then kill -TERM -- -"$pgid" 2>/dev/null || :; else kill -TERM "$pid" 2>/dev/null || :; fi
  i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do i=$((i+1)); sleep .1; done
  if [ "$isolated" = true ]; then kill -KILL -- -"$pgid" 2>/dev/null || :; else kill -KILL "$pid" 2>/dev/null || :; fi
  rm -f "$f"
}
run(){
  uuid=''; service='';
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) uuid=${2:?run id required}; shift 2; valid_run_id "$uuid" || die 'invalid run id' 69;;
      --service) service=${2:?service required}; shift 2;;
      --) shift; break;;
      *) die 'usage: obs run [--service name] -- command [args...]';;
    esac
  done
  [ "$#" -gt 0 ] || die 'run requires command'
  [ -n "$uuid" ] || uuid=$(rand_uuid)
  load_ingest_credential
  project_id=$("$(dirname "$0")/project.sh" ensure)
  scope=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  [ -n "$service" ] || service=${scope##*/}
  [ -n "$service" ] || service=agentotel
  case "$service" in *[!A-Za-z0-9._-]*) die 'invalid service name';; esac
  export OTEL_SERVICE_NAME="$service"
  export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}"
  export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
  export OTEL_EXPORTER_OTLP_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}}"
  existing=${OTEL_RESOURCE_ATTRIBUTES:-}
  case ",$existing," in *,agentotel.project.id=*) die 'OTEL_RESOURCE_ATTRIBUTES already contains agentotel.project.id';; esac
  export OTEL_RESOURCE_ATTRIBUTES="agentotel.project.id=$project_id${existing:+,$existing}"
  unset GATEWAY_INGEST_TOKEN GATEWAY_INGEST_TOKEN_FILE GATEWAY_QUERY_TOKEN GATEWAY_QUERY_TOKEN_FILE GF_SECURITY_ADMIN_PASSWORD
  isolated=false
  if command -v setsid >/dev/null 2>&1; then setsid "$@" & isolated=true; else "$@" & fi
  pid=$!; pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  write_record "$uuid" "$pid" "$pgid" "$isolated" "$(sha "$@")" "$scope"
  printf '%s\n' "$uuid"
  stop_child(){ sig=$1; if [ "$isolated" = true ]; then kill -"$sig" -- -"$pgid" 2>/dev/null || :; else kill -"$sig" "$pid" 2>/dev/null || :; fi; }
  trap 'stop_child INT' INT; trap 'stop_child TERM' TERM; trap 'stop_child HUP' HUP; set +e; wait "$pid"; rc=$?; set -e; clear_record "$uuid"; return "$rc"
}
stop(){ requested=${1:-}; if [ "$requested" = '--run' ]; then f=$(record_for "${2:-}"); else scope_fp=$(sha "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"); files=''; n=0; for f in "$REG"/*.json; do [ -f "$f" ] || continue; s=$(sed -n 's/.*"scope_fingerprint":"\([0-9a-f]*\)".*/\1/p' "$f"); [ "$s" = "$scope_fp" ] || continue; files="$files $f"; n=$((n+1)); done; [ "$n" -eq 1 ] || die 'scope_ambiguous' 69; f=$(printf '%s' "$files" | awk '{print $1}'); fi; signal_record "$f"; }
case "${1:-}" in --|--service|--run) run "$@";; start|exec) shift; run "$@";; stop) shift; stop "$@";; runs) for f in "$REG"/*.json; do [ -f "$f" ] && cat "$f"; done;; *) die 'invalid run command';; esac
