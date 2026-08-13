#!/bin/sh
set -eu
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/volumes.sh"
credentials="$(dirname "$0")/credentials.sh"
"$credentials" ensure >/dev/null
command -v docker >/dev/null 2>&1 || die 'docker is unavailable'
volume_inventory_load || die 'unable to inspect Docker volumes; refusing to create or relabel volumes'
mkdirs
uuid=$("$(dirname "$0")/dispatch.sh" stack-id)
project=${COMPOSE_PROJECT_NAME:-dev-observability}
for volume in otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data grafana-data; do
  name="${project}_${volume}"
  if volume_exists "$name"; then
    stack=$(volume_label "$name")
    owner=$(volume_project_label "$name")
    if [ "$stack" != "$uuid" ] || [ "$owner" != "$project" ]; then die "unsafe volume identity: $name"; fi
  else
    docker volume create --label "com.agentotel.stack=$uuid" --label "com.docker.compose.project=$project" "$name" >/dev/null
  fi
done
if [ "${1:-}" = up ]; then
  shift
  exec "$(dirname "$0")/compose.sh" up -d "$@"
fi
printf '%s\n' "$uuid"
