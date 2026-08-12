#!/bin/sh
# Read-only volume identity inspection. Sourced by doctor/storage; never mutates Docker.
volume_project=${COMPOSE_PROJECT_NAME:-dev-observability}
volume_allowlist="${volume_project}_otelcol-queue ${volume_project}_victorialogs-data ${volume_project}_victoriametrics-data ${volume_project}_victoriatraces-data ${volume_project}_grafana-data"
volume_inventory_loaded=0
volume_inventory_error=0
volume_inventory_names=''
volume_inventory_data=''
volume_inventory_load() {
  if [ "$volume_inventory_loaded" -eq 1 ]; then
    [ "$volume_inventory_error" -eq 0 ]
    return $?
  fi
  volume_all_names=$(docker volume ls --format '{{.Name}}' 2>/dev/null) || {
    volume_inventory_error=1
    volume_inventory_loaded=1
    return 1
  }
  volume_inventory_names=''
  for volume_name in $volume_allowlist; do
    for existing_name in $volume_all_names; do
      [ "$existing_name" = "$volume_name" ] || continue
      volume_inventory_names="$volume_inventory_names $volume_name"
    done
  done
  if [ -n "$volume_inventory_names" ]; then
    volume_inventory_data=$(
    # The inventory is an internal, space-delimited list of Docker names.
    # shellcheck disable=SC2086
    set -- $volume_inventory_names
      docker volume inspect -f '{{.Name}}\t{{ index .Labels "com.agentotel.stack" }}\t{{ index .Labels "com.docker.compose.project" }}' "$@" 2>/dev/null
    ) || {
      volume_inventory_error=1
      volume_inventory_loaded=1
      volume_inventory_names=''
      volume_inventory_data=''
      return 1
    }
  fi
  volume_inventory_loaded=1
  return 0
}
volume_inventory_has() {
  volume_inventory_load || return 2
  for volume_name in $volume_inventory_names; do
    [ "$volume_name" = "$1" ] && return 0
  done
  return 1
}
volume_inventory_field() {
  volume_inventory_load || return 2
  printf '%s\n' "$volume_inventory_data" | awk -F '\t' -v wanted="$1" -v field="$2" '$1 == wanted { print $field; exit }'
}
volume_label() { volume_inventory_field "$1" 2; }
volume_project_label() { volume_inventory_field "$1" 3; }
volume_exists() { volume_inventory_has "$1"; }
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
