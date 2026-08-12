#!/bin/sh
# Read-only volume identity inspection. Sourced by doctor/storage; never mutates Docker.
volume_project=${COMPOSE_PROJECT_NAME:-dev-observability}
volume_allowlist="${volume_project}_otelcol-queue ${volume_project}_victorialogs-data ${volume_project}_victoriametrics-data ${volume_project}_victoriatraces-data ${volume_project}_grafana-data"
volume_label() { docker volume inspect -f '{{ index .Labels "com.agentotel.stack" }}' "$1" 2>/dev/null || true; }
volume_project_label() { docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true; }
volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }
legacy_volume_list() {
  for volume_name in $volume_allowlist; do
    volume_exists "$volume_name" || continue
    volume_stack=$(volume_label "$volume_name")
    [ -n "$volume_stack" ] || printf '%s\n' "$volume_name"
  done
}
volume_json_array() {
  first=1; printf '['
  while IFS= read -r volume_name; do
    [ -n "$volume_name" ] || continue
    [ "$first" -eq 1 ] || printf ','
    printf '"%s"' "$(json_escape "$volume_name")"; first=0
  done
  printf ']'
}
volume_mismatch_list() {
  expected=$1
  [ -n "$expected" ] || return 0
  for volume_name in $volume_allowlist; do
    volume_exists "$volume_name" || continue
    volume_stack=$(volume_label "$volume_name")
    volume_compose_project=$(volume_project_label "$volume_name")
    [ "$volume_stack" = "$expected" ] && [ "$volume_compose_project" = "$volume_project" ] || printf '%s\n' "$volume_name"
  done
}
