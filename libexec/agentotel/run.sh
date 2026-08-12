#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
mkdirs
REG="$STATE/runs"; LOCK="$REG.lock"; mkdir -p "$REG"; chmod 700 "$REG"
lock(){ i=0; while ! mkdir "$LOCK" 2>/dev/null; do i=$((i+1)); [ "$i" -lt 100 ] || die 'registry busy' 75; sleep .01; done; trap 'rmdir "$LOCK" 2>/dev/null || :' EXIT; }
unlock(){ rmdir "$LOCK" 2>/dev/null || :; trap - EXIT; }
sha(){ printf '%s' "$*" | shasum -a 256 | awk '{print $1}'; }
proc_fp(){ ps -o command= -p "$1" 2>/dev/null | sed 's/^ *//' | shasum -a 256 | awk '{print $1}'; }
startid(){ ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//' || :; }
write_record(){ lock; (umask 077; printf '{"schema":1,"run_id":"%s","pid":%s,"pgid":%s,"process_start":"%s","argv_fingerprint":"%s","process_fingerprint":"%s","scope":"%s"}\n' "$1" "$2" "$3" "$(startid "$2")" "$4" "$(proc_fp "$2")" "$5" >"$REG/$1.tmp.$$"; chmod 600 "$REG/$1.tmp.$$"; mv -f "$REG/$1.tmp.$$" "$REG/$1.json"); unlock; }
clear_record(){ lock; rm -f "$REG/$1.json"; unlock; }
valid_run_id(){ valid_uuid "$1"; }
record_for(){ id=$1; valid_run_id "$id" || die 'invalid run id' 69; f="$REG/$id.json"; [ -f "$f" ] || die 'run not found' 69; printf '%s\n' "$f"; }
verify_record(){ f=$1; pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f"); pgid=$(sed -n 's/.*"pgid":\([0-9][0-9]*\).*/\1/p' "$f"); old=$(sed -n 's/.*"process_start":"\([^"]*\)".*/\1/p' "$f"); pf=$(sed -n 's/.*"process_fingerprint":"\([^"]*\)".*/\1/p' "$f"); now=$(startid "$pid"); if [ -z "$now" ] || [ "$now" != "$old" ]; then die 'stale or pid reuse' 69; fi; [ "$(proc_fp "$pid")" = "$pf" ] || die 'process fingerprint mismatch' 69; [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pgid" ] || die 'pgid ownership mismatch' 69; }
signal_record(){ f=$1; verify_record "$f"; kill -TERM -- -"$pgid" 2>/dev/null || :; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do i=$((i+1)); sleep .1; done; kill -KILL -- -"$pgid" 2>/dev/null || :; rm -f "$f"; }
run(){ uuid=''; [ "${1:-}" = '--run' ] && { uuid=$2; shift 2; valid_run_id "$uuid" || die 'invalid run id' 69; }; [ "${1:-}" = '--' ] && shift; [ "$#" -gt 0 ] || die 'run requires command'; [ -n "$uuid" ] || uuid=$(rand_uuid); fp=$(sha "$@"); export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-agentotel}"; scope=$(git rev-parse --show-toplevel 2>/dev/null || pwd); if command -v setsid >/dev/null 2>&1; then setsid "$@" & else "$@" & fi; pid=$!; pgid=$(ps -o pgid= -p "$pid" | tr -d ' '); write_record "$uuid" "$pid" "$pgid" "$fp" "$scope"; printf '%s\n' "$uuid"; stop_child(){ sig=$1; kill -"$sig" -- -"$pgid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || :; }; trap 'stop_child INT' INT; trap 'stop_child TERM' TERM; trap 'stop_child HUP' HUP; set +e; wait "$pid"; rc=$?; set -e; clear_record "$uuid"; return "$rc"; }
stop(){ requested=${1:-}; if [ "$requested" = '--run' ]; then f=$(record_for "${2:-}"); else scope=$(git rev-parse --show-toplevel 2>/dev/null || pwd); files=''; n=0; for f in "$REG"/*.json; do [ -f "$f" ] || continue; s=$(sed -n 's/.*"scope":"\([^"]*\)".*/\1/p' "$f"); [ "$s" = "$scope" ] || continue; files="$files $f"; n=$((n+1)); done; [ "$n" -eq 1 ] || die 'scope_ambiguous' 69; f=$(printf '%s' "$files" | awk '{print $1}'); fi; signal_record "$f"; }
case "${1:-}" in --) shift; run "$@";; start|exec) shift; run "$@";; stop) shift; stop "$@";; runs) for f in "$REG"/*.json; do [ -f "$f" ] && cat "$f"; done;; *) die 'invalid run command';; esac
