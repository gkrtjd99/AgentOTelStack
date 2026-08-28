#!/bin/sh
# Read-only volume identity inspection. Sourced by doctor/storage; never mutates Docker.
volume_project=${COMPOSE_PROJECT_NAME:-dev-observability}
volume_allowlist=$(agentotel_active_volume_names "$volume_project")
volume_inventory_loaded=0
volume_inventory_error=0
volume_inventory_names=''
volume_inventory_data=''
# Docker's formatter implementations have differed in how they interpret
# backslash escapes in templates.  Use a literal delimiter for new requests,
# and normalize the two historical tab spellings when reading a record so an
# implementation that still returns either spelling remains safe to consume.
volume_record_field() {
  wanted=$1
  field=$2
  awk -v wanted="$wanted" -v field="$field" '
    {
      record = $0
      gsub(sprintf("%c", 9), "|", record)
      gsub(/\\t/, "|", record)
      fields = split(record, values, "|")
      if (fields >= field && values[1] == wanted) {
        print values[field]
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  '
}
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
  volume_inventory_names=$(
    while IFS= read -r volume_name; do
      [ -n "$volume_name" ] || continue
      if printf '%s\n' "$volume_all_names" | grep -F -x -- "$volume_name" >/dev/null 2>&1; then
        printf '%s\n' "$volume_name"
      fi
    done <<EOF
$volume_allowlist
EOF
  )
  if [ -n "$volume_inventory_names" ]; then
    volume_inventory_data=$(
      set --
      while IFS= read -r volume_name; do
        [ -n "$volume_name" ] || continue
        set -- "$@" "$volume_name"
      done <<EOF
$volume_inventory_names
EOF
      docker volume inspect -f '{{.Name}}|{{ index .Labels "com.agentotel.stack" }}|{{ index .Labels "com.docker.compose.project" }}' "$@" 2>/dev/null
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
  while IFS= read -r volume_name; do
    [ "$volume_name" = "$1" ] && return 0
  done <<EOF
$volume_inventory_names
EOF
  return 1
}
volume_inventory_field() {
  volume_inventory_load || return 2
  printf '%s\n' "$volume_inventory_data" | volume_record_field "$1" "$2"
}
volume_label() { volume_inventory_field "$1" 2; }
volume_project_label() { volume_inventory_field "$1" 3; }
volume_exists() { volume_inventory_has "$1"; }
legacy_volume_list() {
  while IFS= read -r volume_name; do
    [ -n "$volume_name" ] || continue
    volume_exists "$volume_name" || continue
    volume_stack=$(volume_label "$volume_name")
    [ -n "$volume_stack" ] || printf '%s\n' "$volume_name"
  done <<EOF
$volume_allowlist
EOF
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
  while IFS= read -r volume_name; do
    [ -n "$volume_name" ] || continue
    volume_exists "$volume_name" || continue
    volume_stack=$(volume_label "$volume_name")
    volume_compose_project=$(volume_project_label "$volume_name")
    [ "$volume_stack" = "$expected" ] && [ "$volume_compose_project" = "$volume_project" ] || printf '%s\n' "$volume_name"
  done <<EOF
$volume_allowlist
EOF
}
