#!/bin/sh
# shellcheck disable=SC2153
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/volumes.sh"
if ! volume_inventory_load; then
  if [ "${AGENTOTEL_JSON:-0}" = 1 ]; then
    printf '%s\n' '{"status":"unavailable","check":"volumes","migration_required":false,"legacy_volumes":[],"mismatched_volumes":[]}'
  else
    printf '%s\n' 'doctor: unavailable (unable to inspect Docker volumes)'
  fi
  exit 2
fi
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd); state="$STATE/stack.uuid"; uuid=''; identity=missing
if [ -f "$state" ]; then uuid=$(cat "$state"); valid_uuid "$uuid" || { uuid=''; identity=invalid; }; [ -n "$uuid" ] && identity=present; fi
compose=$(docker compose config --services 2>/dev/null || true); running=$(docker compose ps --status running --services 2>/dev/null || true)
legacy=$(legacy_volume_list)
df_tool=${AGENTOTEL_DF_CMD:-df}; free=$($df_tool -Pk "$root" | awk 'NR==2{print $4}'); case "$free" in *[!0-9]*|'') free=0;; esac
status=ok; [ "$free" -lt 1048576 ] && status=warn
mismatch=$(volume_mismatch_list "$uuid"); [ -n "$legacy$mismatch" ] && { migration_required=1; status=warn; } || migration_required=0
if [ "$identity" != present ]; then status=warn; fi
if [ "${AGENTOTEL_JSON:-0}" = 1 ]; then printf '{"status":"%s","identity":"%s","stack_uuid":"%s","compose_services":"%s","running_services":"%s","free_kib":%s,"migration_required":%s,"legacy_volumes":' "$status" "$identity" "$uuid" "$(printf '%s' "$compose" | tr '\n' ',')" "$(printf '%s' "$running" | tr '\n' ',')" "$free" "$migration_required"; printf '%s' "$(printf '%s\n' "$legacy" | volume_json_array)"; printf ',"mismatched_volumes":'; printf '%s' "$(printf '%s\n' "$mismatch" | volume_json_array)"; printf ',"migration_guidance":"stop stack, snapshot/backup each listed volume, copy and verify data before switching labels"}\n'; else printf 'doctor: %s\nstack_identity: %s\nstack_uuid: %s\nfree_kib: %s\nmigration_required: %s\n' "$status" "$identity" "${uuid:-missing}" "$free" "$migration_required"; [ -n "$legacy" ] && printf 'legacy volumes (unlabeled):\n%s\n' "$legacy"; [ -n "$mismatch" ] && printf 'mismatched volumes (unsafe identity):\n%s\n' "$mismatch"; [ -n "$legacy$mismatch" ] && printf 'backup guidance: stop stack, snapshot/backup each volume, copy and verify before switching labels. No automatic migration is performed.\n'; fi
[ "$status" = warn ] && exit 1; exit 0
