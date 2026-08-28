#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
if [ "${1:-}" != --all ] || [ "${2:-}" != --confirm ]; then die 'usage: obs reset --all --confirm'; fi
[ -t 0 ] || die 'reset requires an interactive TTY'
mkdirs
# Setup and reset share one lifecycle lock. Hold it across Compose resolution,
# stop, holder checks, final ownership re-inspection, and every volume removal.
lifecycle_lock="$STATE/lifecycle.lock"
lock_acquire "$lifecycle_lock" lifecycle 1000
lifecycle_lock_token=$AGENTOTEL_LOCK_TOKEN
unlock_lifecycle(){ lock_release "$lifecycle_lock" "$lifecycle_lock_token" >/dev/null 2>&1 || :; trap - EXIT HUP INT TERM; }
cleanup_lifecycle(){ lifecycle_rc=$?; trap - EXIT HUP INT TERM; unlock_lifecycle; exit "$lifecycle_rc"; }
trap cleanup_lifecycle EXIT
trap 'exit 1' HUP INT TERM
# Reset still needs the real Compose interpolation inputs even though it does
# not start a profiled workload. Read the canonical two-key store first, and
# pass the values only as environment assignments to the child Compose process.
credentials="$(dirname "$0")/credentials.sh"
"$credentials" ensure >/dev/null
compose_ingest=$(credential_value ingest_token)
compose_query=$(credential_value query_token)
# Keep the loaded values unexported except for compose_child's command-scoped
# assignments. Volume and process-inspection Docker calls must not inherit them.
unset GATEWAY_INGEST_TOKEN GATEWAY_INGEST_TOKEN_FILE GATEWAY_QUERY_TOKEN GATEWAY_QUERY_TOKEN_FILE
scrub_retired_grafana_env
f="$STATE/stack.uuid"
[ ! -L "$f" ] || die 'symlink rejected: stack identity'
[ -f "$f" ] || die 'stack identity unavailable'
uuid=$(cat "$f"); valid_uuid "$uuid" || die 'invalid stack UUID'; printf 'Current stack UUID: %s\nType it to confirm: ' "$uuid"; IFS= read -r answer; [ "$answer" = "$uuid" ] || die 'UUID mismatch'; project=${COMPOSE_PROJECT_NAME:-dev-observability}
command -v docker >/dev/null 2>&1 || die 'docker is unavailable'
compose_child(){
  GATEWAY_INGEST_TOKEN="$compose_ingest" GATEWAY_QUERY_TOKEN="$compose_query" docker compose "$@"
}
# Resolve the active compose file/project before touching Docker resources.  In
# particular, do not fall back to a generic `docker compose down` project.
compose_child -p "$project" config >/dev/null 2>&1 || die 'unable to resolve the current compose project/assets'
allow=$(agentotel_active_volume_names "$project"); count=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  [ -n "$(docker volume inspect "$v" 2>/dev/null)" ] || continue
  count=$((count+1)); actual=$(docker volume inspect -f '{{ index .Labels "com.agentotel.stack" }}' "$v" 2>/dev/null || true)
  [ "$actual" = "$uuid" ] || die "volume identity mismatch: $v"
  actual_project=$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$v" 2>/dev/null || true)
  [ "$actual_project" = "$project" ] || die "volume project mismatch: $v"
done <<EOF
$allow
EOF
[ "$count" -gt 0 ] || die 'no exact stack volumes found'
# Stop and remove only this compose project.  Never pass --volumes/-v.
compose_child -p "$project" down --remove-orphans >/dev/null 2>&1 || die 'stack stop/remove failed; volumes were preserved'
# A container outside this compose project may still hold one of the exact
# volumes.  Refuse deletion rather than guessing ownership.
while IFS= read -r v; do
  [ -n "$v" ] || continue
  [ -n "$(docker volume inspect "$v" 2>/dev/null)" ] || continue
  holders=$(docker ps -aq --filter "volume=$v" 2>/dev/null || true)
  [ -z "$holders" ] || die "volume is still in use: $v"
done <<EOF
$allow
EOF
while IFS= read -r v; do
  [ -n "$v" ] || continue
  if [ -n "$(docker volume inspect "$v" 2>/dev/null)" ]; then
    # Re-inspect ownership immediately before each rm. The lifecycle lock
    # excludes cooperating setup/reset actors; Docker itself does not provide
    # an inspect-and-remove transaction against an unrelated actor.
    labels=$(docker volume inspect -f '{{ index .Labels "com.agentotel.stack" }}|{{ index .Labels "com.docker.compose.project" }}' "$v" 2>/dev/null) || die "unable to verify volume ownership: $v"
    [ "$labels" = "$uuid|$project" ] || die "volume ownership changed before removal: $v"
    holders=$(docker ps -aq --filter "volume=$v" 2>/dev/null || true)
    [ -z "$holders" ] || die "volume is still in use: $v"
    docker volume rm "$v" >/dev/null || die "volume removal failed: $v"
  fi
done <<EOF
$allow
EOF
printf '{"status":"reset","project":"%s","stack_uuid":"%s"}\n' "$project" "$uuid"
