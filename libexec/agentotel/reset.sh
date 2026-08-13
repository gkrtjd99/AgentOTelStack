#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
if [ "${1:-}" != --all ] || [ "${2:-}" != --confirm ]; then die 'usage: obs reset --all --confirm'; fi
[ -t 0 ] || die 'reset requires an interactive TTY'
mkdirs; f="$STATE/stack.uuid"; [ -f "$f" ] || die 'stack identity unavailable'; uuid=$(cat "$f"); valid_uuid "$uuid" || die 'invalid stack UUID'; printf 'Current stack UUID: %s\nType it to confirm: ' "$uuid"; IFS= read -r answer; [ "$answer" = "$uuid" ] || die 'UUID mismatch'; project=${COMPOSE_PROJECT_NAME:-dev-observability}
command -v docker >/dev/null 2>&1 || die 'docker is unavailable'
# Resolve the active compose file/project before touching Docker resources.  In
# particular, do not fall back to a generic `docker compose down` project.
docker compose -p "$project" config >/dev/null 2>&1 || die 'unable to resolve the current compose project/assets'
allow="${project}_otelcol-queue ${project}_victorialogs-data ${project}_victoriametrics-data ${project}_victoriatraces-data ${project}_grafana-data"; count=0
for v in $allow; do
  [ -n "$(docker volume inspect "$v" 2>/dev/null)" ] || continue
  count=$((count+1)); actual=$(docker volume inspect -f '{{ index .Labels "com.agentotel.stack" }}' "$v" 2>/dev/null || true)
  [ "$actual" = "$uuid" ] || die "volume identity mismatch: $v"
  actual_project=$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$v" 2>/dev/null || true)
  [ "$actual_project" = "$project" ] || die "volume project mismatch: $v"
done
[ "$count" -gt 0 ] || die 'no exact stack volumes found'
# Stop and remove only this compose project.  Never pass --volumes/-v.
docker compose -p "$project" down --remove-orphans >/dev/null 2>&1 || die 'stack stop/remove failed; volumes were preserved'
# A container outside this compose project may still hold one of the exact
# volumes.  Refuse deletion rather than guessing ownership.
for v in $allow; do
  [ -n "$(docker volume inspect "$v" 2>/dev/null)" ] || continue
  holders=$(docker ps -aq --filter "volume=$v" 2>/dev/null || true)
  [ -z "$holders" ] || die "volume is still in use: $v"
done
for v in $allow; do
  if [ -n "$(docker volume inspect "$v" 2>/dev/null)" ]; then
    docker volume rm "$v" >/dev/null || die "volume removal failed: $v"
  fi
done
printf '{"status":"reset","project":"%s","stack_uuid":"%s"}\n' "$project" "$uuid"
