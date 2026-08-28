#!/usr/bin/env bash
# Make's checkout Compose boundary: fixed repository file, generated project,
# and no inherited Compose selectors.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command="${1:-}"
shift || true

seed="$(printf '%s' "$ROOT" | shasum -a 256 | awk '{print substr($1,1,10)}')"
project="agentotel-dev-$seed"
project_id_override=''
while [[ "$command" == --project || "$command" == --project-id ]]; do
  option="$command"
  value="${1:-}"
  [[ -n "$value" ]] || { echo "make-compose: $option requires a value" >&2; exit 2; }
  shift
  command="${1:-}"
  shift || true
  if [[ "$option" == --project ]]; then
    project="$value"
  else
    project_id_override="$value"
  fi
done
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || {
  echo "make-compose: invalid Compose project '$project'" >&2
  exit 2
}
project_uuid=''
resolve_project_uuid() {
  if [[ -n "$project_id_override" ]]; then
    project_uuid="$project_id_override"
  else
    project_uuid="$(env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
      AGENTOTEL_DEV_MODE=1 "$ROOT/bin/obs" project ensure)"
  fi
  [[ "$project_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    echo 'make-compose: project ID is not UUIDv4' >&2
    exit 1
  }
}

run_setup() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 COMPOSE_PROJECT_NAME="$project" \
    "$ROOT/bin/obs" setup
}
run_compose() {
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 COMPOSE_PROJECT_NAME="$project" AGENTOTEL_PROJECT_ID="$project_uuid" \
    "$ROOT/bin/obs" compose -f "$ROOT/docker-compose.yml" -p "$project" "$@"
}

dashboard_token_distinct() {
  local token="$1"
  if [[ -n "${GATEWAY_QUERY_TOKEN:-}" ]]; then
    [[ "$token" != "$GATEWAY_QUERY_TOKEN" ]]
    return
  fi
  # Check the credential-store value without printing or exporting it into the
  # Make process. The child exits only with the comparison result.
  env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROFILES \
    AGENTOTEL_DEV_MODE=1 "$ROOT/bin/obs" credentials run -- \
    sh -c "[ \"\$GATEWAY_QUERY_TOKEN\" != \"\$1\" ]" sh "$token" >/dev/null 2>&1
}
generate_dashboard_token() {
  local token
  for _ in 1 2 3; do
    token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$token" =~ ^[0-9a-f]{64}$ ]] && dashboard_token_distinct "$token"; then
      printf '%s' "$token"
      return 0
    fi
  done
  echo 'make-compose: unable to generate a distinct dashboard client token' >&2
  return 1
}

case "$command" in
  setup)
    resolve_project_uuid
    run_setup
    ;;
  compose)
    resolve_project_uuid
    run_compose "$@"
    ;;
  dashboard)
    resolve_project_uuid
    run_setup >/dev/null
    dashboard_url="${DASHBOARD_URL:-http://127.0.0.1:${DASHBOARD_HOST_PORT:-3001}}"
    if ! dashboard_url="$("$ROOT/scripts/validate-dashboard-url.sh" "$dashboard_url" "${DASHBOARD_HOST_PORT:-3001}" 2>&1)"; then
      echo "make-compose: $dashboard_url" >&2
      exit 1
    fi
    DASHBOARD_CLIENT_TOKEN="$(generate_dashboard_token)"
    export DASHBOARD_CLIENT_TOKEN
    run_compose --profile dashboard up -d --build --force-recreate dashboard
    DASHBOARD_URL="$dashboard_url" \
    DASHBOARD_CLIENT_TOKEN="$DASHBOARD_CLIENT_TOKEN" \
      "$ROOT/scripts/dashboard-readiness.sh"
    printf 'dashboard bootstrap URL: %s/#token=%s\n' \
      "$dashboard_url" "$DASHBOARD_CLIENT_TOKEN"
    ;;
  *)
    echo 'usage: make-compose.sh [--project PROJECT] [--project-id UUIDv4] {setup|compose|dashboard} ...' >&2
    exit 2
    ;;
esac
