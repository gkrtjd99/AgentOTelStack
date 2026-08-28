#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
cmd=${1:-}; shift || :
case "$cmd" in
 version) printf '{"version":"%s","schema":1}\n' "$VERSION";;
 stack-id)
  mkdirs
  f="$STATE/stack.uuid"
  [ ! -L "$f" ] || die 'symlink rejected: stack identity'
  lock="$f.lock"
  lock_acquire "$lock" 'stack identity' 1000
  stack_lock_token=$AGENTOTEL_LOCK_TOKEN
  unlock_stack(){ lock_release "$lock" "$stack_lock_token" >/dev/null 2>&1 || :; trap - EXIT HUP INT TERM; }
  trap unlock_stack EXIT
  trap 'unlock_stack; exit 1' HUP INT TERM
  # Re-check after taking the lock: a competing resolver may have persisted
  # the winner while this process was waiting. Never re-key that identity.
  [ ! -L "$f" ] || die 'symlink rejected: stack identity'
  requested="${AGENTOTEL_STACK_UUID:-}"
  if [ -n "$requested" ]; then
    case "$requested" in *[!0-9A-Fa-f-]*) die 'invalid AGENTOTEL_STACK_UUID';; esac
    requested=$(printf '%s' "$requested" | tr 'A-F' 'a-f')
    valid_uuid "$requested" || die 'invalid AGENTOTEL_STACK_UUID'
  fi
  read_persisted_stack_uuid(){
    [ ! -L "$f" ] || die 'symlink rejected: stack identity'
    [ -f "$f" ] || die 'stack identity is not a regular file'
    uuid=$(awk 'NR == 1 { value = $0; next } { invalid = 1 } END { if (NR != 1 || invalid) exit 1; print value }' "$f") || die 'invalid stack UUID'
    valid_uuid "$uuid" || die 'invalid stack UUID'
  }
  if [ -e "$f" ] || [ -L "$f" ]; then
    read_persisted_stack_uuid
    if [ -n "$requested" ] && [ "$requested" != "$uuid" ]; then
      die 'AGENTOTEL_STACK_UUID does not match persisted stack UUID'
    fi
  else
    uuid="${requested:-$(rand_uuid | tr A-F a-f)}"
    valid_uuid "$uuid" || die 'generated invalid stack UUID'
    tmp="$f.tmp.$$"
    (umask 077; set -C; printf '%s\n' "$uuid" >"$tmp") || die 'unable to persist stack UUID'
    chmod 600 "$tmp"
    # ln creates the destination name exclusively and atomically. If an
    # external resolver won despite the lock, return its persisted identity.
    if ln "$tmp" "$f" 2>/dev/null; then
      rm -f "$tmp"
    else
      rm -f "$tmp"
      read_persisted_stack_uuid
      if [ -n "$requested" ] && [ "$requested" != "$uuid" ]; then
        die 'AGENTOTEL_STACK_UUID does not match persisted stack UUID'
      fi
    fi
  fi
  printf '%s\n' "$uuid"
  unlock_stack
  ;;
 credentials) exec "$(dirname "$0")/credentials.sh" "$@";;
 setup) exec "$(dirname "$0")/setup.sh" "$@";;
 up) exec "$(dirname "$0")/setup.sh" up "$@";;
 down) exec "$(dirname "$0")/compose.sh" --profile demo --profile dashboard down "$@";;
 compose) exec "$(dirname "$0")/compose.sh" "$@";;
 init) exec "$(dirname "$0")/project.sh" init "$@";; project) exec "$(dirname "$0")/project.sh" "$@";;
 source-state) exec "$(dirname "$0")/project.sh" source-state;;
 run) exec "$(dirname "$0")/run.sh" "$@";;
 runs) exec "$(dirname "$0")/run.sh" runs "$@";;
 context|errors|correlate|services) exec "$(dirname "$0")/query.sh" "$cmd" "$@";;
 runtime) case "${1:-}" in list) d=${XDG_DATA_HOME:-$HOME/.local/share}/agentotel; cur=$(readlink "$d/current" 2>/dev/null || echo ''); printf '{"current":"%s","versions":[' "$cur"; first=1; for v in "$d"/*; do [ -d "$v" ] || continue; b=${v##*/}; case "$b" in .*) continue;; esac; [ "$b" = agentotel ] && continue; [ "$b" = current ] || [ "$b" = previous ] && continue; [ "$first" = 1 ] || printf ','; printf '"%s"' "$b"; first=0; done; printf ']}\n';; rollback) d=${XDG_DATA_HOME:-$HOME/.local/share}/agentotel; [ -L "$d/previous" ] || die 'no previous runtime' 69; p=$(readlink "$d/previous"); case "$p" in /*|*/*) die 'invalid previous runtime' 69;; esac; [ -d "$d/$p" ] || die 'invalid previous runtime' 69; c=$(readlink "$d/current"); rm -f "$d/previous"; ln -s "$c" "$d/previous.tmp.$$"; mv -f "$d/previous.tmp.$$" "$d/previous"; ln -s "$p" "$d/current.tmp.$$"; rm -f "$d/current"; mv -f "$d/current.tmp.$$" "$d/current"; echo '{"status":"rolled_back"}';; *) die 'invalid runtime command';; esac;;
 env) [ "${1:-}" = write ] || die 'invalid env command'; shift; [ "$#" -eq 0 ] || die 'env write accepts no arguments'; mkdirs; : > "$STATE/env"; chmod 600 "$STATE/env"; echo '{"status":"written"}';;
 doctor) exec "$(dirname "$0")/doctor.sh" "$@";;
 storage|disk|cardinality|canary) exec "$(dirname "$0")/storage.sh" "$cmd" "$@";;
 reset) exec "$(dirname "$0")/reset.sh" "$@";;
 migrate) if [ "${1:-}" != volumes ] || [ "${2:-}" != --confirm ]; then die 'usage: obs migrate volumes --confirm'; fi; die 'volume migration is intentionally manual: stop stack, snapshot/backup listed volumes, copy data, verify, then recreate with stack-id label';;
 gateway) exec "$(dirname "$0")/gateway.sh" "$@";;
 *) die 'unknown subcommand';;
esac
