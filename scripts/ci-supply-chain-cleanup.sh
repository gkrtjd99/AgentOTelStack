#!/usr/bin/env bash
# Remove only the exact supply-chain Compose project, its four owned volumes,
# and its seven exact runtime image tags. Every Docker query distinguishes an
# empty result (not found) from an operational failure; no broad prune is used.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
: "${AGENTOTEL_STACK_UUID:?AGENTOTEL_STACK_UUID is required}"
: "${GATEWAY_INGEST_TOKEN:?GATEWAY_INGEST_TOKEN is required for Compose interpolation}"
: "${GATEWAY_QUERY_TOKEN:?GATEWAY_QUERY_TOKEN is required for Compose interpolation}"
project=$COMPOSE_PROJECT_NAME
uuid=$AGENTOTEL_STACK_UUID
runtime=${AGENTOTEL_RUNTIME_VERSION:-dev}
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || {
  echo "cleanup: invalid Compose project: $project" >&2
  exit 2
}
[[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || {
  echo "cleanup: invalid stack UUID" >&2
  exit 2
}
[[ "$runtime" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "cleanup: invalid runtime image suffix: $runtime" >&2
  exit 2
}
# shellcheck source=../libexec/agentotel/common.sh
. "$ROOT/libexec/agentotel/common.sh"
volumes=()
while IFS= read -r volume; do
  [[ -n "$volume" ]] && volumes+=("$volume")
done < <(agentotel_active_volume_names "$project")
[[ "${#volumes[@]}" -eq 4 ]] || {
  echo 'cleanup: canonical volume contract did not return exactly four names' >&2
  exit 1
}
images=(
  "dev-observability/app:$runtime"
  "dev-observability/gateway:$runtime"
  "dev-observability/dashboard:$runtime"
  "dev-observability/victorialogs:v1.52.0-health-$runtime"
  "dev-observability/victoriametrics:v1.150.0-health-$runtime"
  "dev-observability/victoriatraces:v0.11.0-health-$runtime"
  "dev-observability/otel-collector:v0.159.0-health-$runtime"
)

# Query helpers return 0 with an empty stdout for absence, and return nonzero
# only for an operational Docker/API error. Callers must not use `inspect ||
# continue`, which turns a daemon outage into a false PASS.
docker_list() {
  local label=$1; shift
  local result rc
  if result="$(docker "$@" 2> >(while IFS= read -r line; do printf 'cleanup: Docker %s: %s\n' "$label" "$line" >&2; done))"; then
    printf '%s' "$result"
    return 0
  else
    rc=$?
    echo "cleanup: Docker $label operation failed (rc=$rc)" >&2
    return "$rc"
  fi
}

project_containers() { docker_list 'container listing' ps -aq --filter "label=com.docker.compose.project=$project"; }
project_networks() { docker_list 'network listing' network ls -q --filter "label=com.docker.compose.project=$project"; }
project_volumes() { docker_list 'volume listing' volume ls -q --filter "label=com.docker.compose.project=$project"; }
exact_volume() { docker_list "volume lookup $1" volume ls -q --filter "name=^$1$"; }
exact_network() { docker_list "network lookup $1" network ls -q --filter "name=^$1$"; }
exact_image() { docker_list "image lookup $1" image ls -q --no-trunc --filter "reference=$1"; }

resource_labels() {
  local kind=$1 id=$2
  case "$kind" in
    container) docker inspect -f '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.agentotel.stack"}}' "$id" ;;
    network) docker network inspect -f '{{.Name}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.agentotel.stack"}}' "$id" ;;
    volume) docker volume inspect -f '{{.Name}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.agentotel.stack"}}' "$id" ;;
    image) docker image inspect -f '{{.Id}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.agentotel.stack"}}' "$id" ;;
    *) echo "cleanup: internal unknown resource class: $kind" >&2; return 2 ;;
  esac
}

require_owned_labels() {
  local kind=$1 id=$2 expected_name=${3:-} inspected name owner stack
  if ! inspected="$(resource_labels "$kind" "$id" 2>/dev/null)"; then
    echo "cleanup: unable to inspect $kind $id; refusing destructive operation" >&2
    return 1
  fi
  IFS='|' read -r name owner stack <<<"$inspected"
  if [[ -n "$expected_name" && "$name" != "$expected_name" ]]; then
    echo "cleanup: $kind name mismatch: expected $expected_name, got $name" >&2
    return 1
  fi
  if [[ -n "$owner" && "$owner" != "$project" ]]; then
    echo "cleanup: $kind has mismatched Compose project label: $id" >&2
    return 1
  fi
  if [[ -n "$stack" && "$stack" != "$uuid" ]]; then
    echo "cleanup: $kind has mismatched stack label: $id" >&2
    return 1
  fi
  if [[ "$kind" == image ]]; then
    # Build images do not consistently inherit Compose labels across Docker
    # versions. Their exact runtime reference plus successful inspect is the
    # provenance check; any labels that do exist are still enforced above.
    return 0
  fi
  # Compose always supplies the project label. External volumes also carry the
  # stack UUID from setup; networks/containers may not have a custom stack label
  # on older Compose versions, so validate it whenever it is present.
  [[ -n "$owner" ]] || {
    echo "cleanup: $kind is missing exact project ownership label: $id" >&2
    return 1
  }
  if [[ "$kind" == volume && -z "$stack" ]]; then
    echo "cleanup: volume is missing exact stack ownership label: $id" >&2
    return 1
  fi
}

preflight() {
  local ids id found expected
  ids="$(project_containers)" || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    require_owned_labels container "$id" || return 1
  done <<<"$ids"
  ids="$(project_networks)" || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    require_owned_labels network "$id" || return 1
  done <<<"$ids"
  # Any project-labeled volume outside the canonical four is an existing
  # project collision. Inspect it before Compose down, while it is still safe.
  ids="$(project_volumes)" || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    expected=''
    for volume in "${volumes[@]}"; do [[ "$id" == "$volume" ]] && expected=$volume; done
    [[ -n "$expected" ]] || {
      echo "cleanup: unexpected project volume exists; refusing cleanup target: $id" >&2
      return 1
    }
    require_owned_labels volume "$id" "$expected" || return 1
  done <<<"$ids"
  for volume in "${volumes[@]}"; do
    found="$(exact_volume "$volume")" || return 1
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      require_owned_labels volume "$id" "$volume" || return 1
    done <<<"$found"
  done
  echo "cleanup: preflight ownership passed for project $project" >&2
}

compose_down() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR \
    COMPOSE_PROJECT_NAME="$project" \
    AGENTOTEL_STACK_UUID="$uuid" \
    GATEWAY_INGEST_TOKEN="$GATEWAY_INGEST_TOKEN" \
    GATEWAY_QUERY_TOKEN="$GATEWAY_QUERY_TOKEN" \
    docker compose -f "$ROOT/docker-compose.yml" -p "$project" \
      --profile demo --profile dashboard down --remove-orphans
}

# No teardown or removal is attempted until every pre-existing target has been
# proven to belong to this exact project and stack identity.
preflight || {
  echo "cleanup: FAIL before teardown for project $project" >&2
  exit 1
}
cleanup_failed=0
if ! compose_down >/dev/null; then
  echo "cleanup: Compose down failed for $project" >&2
  cleanup_failed=1
fi

for volume in "${volumes[@]}"; do
  found="$(exact_volume "$volume")" || { cleanup_failed=1; continue; }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! require_owned_labels volume "$id" "$volume"; then
      cleanup_failed=1
      continue
    fi
    if ! docker volume rm "$id" >/dev/null; then
      echo "cleanup: failed to remove owned volume $id" >&2
      cleanup_failed=1
    fi
  done <<<"$found"
done

# Post-cleanup zero assertions are mandatory and retain operational errors.
for resource in containers networks volumes; do
  case "$resource" in
    containers) found="$(project_containers)" || { cleanup_failed=1; continue; } ;;
    networks) found="$(project_networks)" || { cleanup_failed=1; continue; } ;;
    volumes) found="$(project_volumes)" || { cleanup_failed=1; continue; } ;;
  esac
  if [[ -n "$found" ]]; then
    echo "cleanup: run-owned $resource remain for $project: $found" >&2
    cleanup_failed=1
  fi
done
for network_suffix in default edge backend dashboard; do
  network="${project}-${network_suffix}"
  found="$(exact_network "$network")" || { cleanup_failed=1; continue; }
  [[ -z "$found" ]] || { echo "cleanup: exact run network remains: $network" >&2; cleanup_failed=1; }
done
for volume in "${volumes[@]}"; do
  found="$(exact_volume "$volume")" || { cleanup_failed=1; continue; }
  [[ -z "$found" ]] || { echo "cleanup: exact run volume remains: $volume" >&2; cleanup_failed=1; }
done

# Exact tags plus a successful inspect are the image provenance boundary. If
# image labels exist, they must agree with this project/stack; unlabeled images
# are still confined to the unique Compose runtime tag and never broad-pruned.
for image in "${images[@]}"; do
  found="$(exact_image "$image")" || { cleanup_failed=1; continue; }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! require_owned_labels image "$image"; then
      cleanup_failed=1
      continue
    fi
    if ! docker image rm -f "$image" >/dev/null; then
      echo "cleanup: failed to remove exact run image $image" >&2
      cleanup_failed=1
    fi
  done <<<"$found"
done
for image in "${images[@]}"; do
  found="$(exact_image "$image")" || { cleanup_failed=1; continue; }
  [[ -z "$found" ]] || { echo "cleanup: exact run image remains: $image" >&2; cleanup_failed=1; }
done

if [[ "$cleanup_failed" -ne 0 ]]; then
  echo "cleanup: FAIL for project $project" >&2
  exit 1
fi
echo "cleanup: PASS for project $project (exact containers, networks, four volumes, and seven runtime images absent)"
