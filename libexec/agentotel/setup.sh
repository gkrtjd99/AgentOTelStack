#!/bin/sh
set -eu
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/volumes.sh"
credentials="$(dirname "$0")/credentials.sh"
"$credentials" ensure >/dev/null
command -v docker >/dev/null 2>&1 || die 'docker is unavailable'
mkdirs

# Serialize identity resolution, the inventory preflight, every external volume
# operation, and (for `setup up`) Compose startup. Reset acquires this same
# cooperative lock, so neither command can observe or remove a partial set.
lifecycle_lock="$STATE/lifecycle.lock"
lock_acquire "$lifecycle_lock" lifecycle 1000
lifecycle_lock_token=$AGENTOTEL_LOCK_TOKEN
unlock_lifecycle(){ lock_release "$lifecycle_lock" "$lifecycle_lock_token" >/dev/null 2>&1 || :; trap - EXIT HUP INT TERM; }
cleanup_lifecycle(){ lifecycle_rc=$?; trap - EXIT HUP INT TERM; unlock_lifecycle; exit "$lifecycle_rc"; }
trap cleanup_lifecycle EXIT
trap 'exit 1' HUP INT TERM

uuid=$("$(dirname "$0")/dispatch.sh" stack-id)
project=${COMPOSE_PROJECT_NAME:-dev-observability}
setup_action=${1:-}
volume_names=$(agentotel_active_volume_names "$project")

# An inventory failure is not an empty inventory. Load it once, then validate
# every pre-existing volume before creating any missing one; this prevents a
# later mismatch from leaving avoidable partial resources behind.
volume_inventory_load || die 'unable to inspect Docker volumes; refusing to create or relabel volumes'
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if volume_exists "$name"; then
    stack=$(volume_label "$name")
    owner=$(volume_project_label "$name")
    if [ "$stack" != "$uuid" ] || [ "$owner" != "$project" ]; then
      die "unsafe volume identity: $name"
    fi
  fi
done <<EOF
$volume_names
EOF

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! volume_exists "$name"; then
    docker volume create --label "com.agentotel.stack=$uuid" --label "com.docker.compose.project=$project" "$name" >/dev/null || die "unable to create volume: $name"
  fi
done <<EOF
$volume_names
EOF

# The cached preflight intentionally cannot certify resources created above.
# Re-inspect the complete allowlist in one Docker call and require exact labels
# on every volume before reporting success.
verify_volume_labels(){
  expected_uuid=$1
  expected_project=$2
  names=$3
  set --
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    set -- "$@" "$name"
  done <<EOF
$names
EOF
  [ "$#" -gt 0 ] || return 1
  inspected=$(docker volume inspect -f '{{.Name}}|{{ index .Labels "com.agentotel.stack" }}|{{ index .Labels "com.docker.compose.project" }}' "$@" 2>/dev/null) || return 1
  for name in "$@"; do
    stack=$(printf '%s\n' "$inspected" | volume_record_field "$name" 2) || return 1
    project=$(printf '%s\n' "$inspected" | volume_record_field "$name" 3) || return 1
    [ "$stack" = "$expected_uuid" ] || return 1
    [ "$project" = "$expected_project" ] || return 1
  done
}
verify_volume_labels "$uuid" "$project" "$volume_names" || die 'post-create volume identity verification failed'

if [ "$setup_action" = up ]; then
  shift
  set +e
  "$(dirname "$0")/compose.sh" up -d "$@"
  compose_rc=$?
  set -e
  exit "$compose_rc"
fi
printf '%s\n' "$uuid"
