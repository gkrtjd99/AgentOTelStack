#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
cmd=${1:-}; shift || :
case "$cmd" in
 version) printf '{"version":"%s","schema":1}\n' "$VERSION";;
 stack-id) mkdirs; f="$STATE/stack.uuid"; if [ -f "$f" ]; then uuid=$(cat "$f"); else uuid=$(rand_uuid | tr A-F a-f); valid_uuid "$uuid" || die 'generated invalid stack UUID'; printf '%s\n' "$uuid" >"$f"; chmod 600 "$f"; fi; valid_uuid "$uuid" || die 'invalid stack UUID'; printf '%s\n' "$uuid";;
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
