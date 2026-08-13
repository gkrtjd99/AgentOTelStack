#!/usr/bin/env bash
# Shared config for the obs/* query helpers. Sourced, not run directly.
# All reads go through the local query Gateway.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:17777}"
if [[ -z "${GATEWAY_QUERY_TOKEN:-}" && -n "${GATEWAY_QUERY_TOKEN_FILE:-}" && -r "${GATEWAY_QUERY_TOKEN_FILE}" ]]; then GATEWAY_QUERY_TOKEN="$(<"${GATEWAY_QUERY_TOKEN_FILE}")"; fi
if [[ -z "${GATEWAY_QUERY_TOKEN:-}" ]]; then die "GATEWAY_QUERY_TOKEN is required"; fi
current_project_id() {
  local root file line schema=0 projects=0 id='' project_re='^project_id[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$'
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in an initialized project; use --global"
  file="$root/.agentotel/project.toml"
  [[ -f "$file" && ! -L "$file" ]] || die "project is not initialized; use --global"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '') continue;;
      'schema = 1') schema=$((schema + 1));;
      project_id*)
        [[ "$line" =~ $project_re ]] || die "invalid project.toml"
        projects=$((projects + 1)); id="${BASH_REMATCH[1]}";;
      *) die "invalid project.toml";;
    esac
  done < "$file"
  (( schema == 1 && projects == 1 )) || die "invalid project.toml"
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die "project.toml requires a UUIDv4 project_id"
  printf '%s' "$id"
}
for arg in "$@"; do [[ "$arg" == --global ]] && AGENTOTEL_GLOBAL=1; done
gateway_get() {
  local path="$1" project
  shift
  if [[ "${AGENTOTEL_GLOBAL:-0}" != 1 ]]; then
    project="$(current_project_id)"
    curl -fsS -H "Authorization: Bearer ${GATEWAY_QUERY_TOKEN}" --get "${GATEWAY_URL}${path}" "$@" --data-urlencode "project=${project}"
  else
    curl -fsS -H "Authorization: Bearer ${GATEWAY_QUERY_TOKEN}" --get "${GATEWAY_URL}${path}" "$@"
  fi
}

# Pretty-print JSON if jq exists, otherwise pass through.
pp() { if command -v jq >/dev/null 2>&1; then jq "${1:-.}"; else cat; fi; }

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required for this command"
}

prom_label_value() {
  local v="${1:-}"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "${v}"
}

log_field_value() {
  local v="${1:-}"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "${v}"
}

duration_value() {
  local v="${1:-}"
  if [[ ! "${v}" =~ ^(5m|15m|1h|6h|24h)$ ]]; then
    die "invalid duration: ${v}"
  fi
  printf '%s' "${v}"
}

limit_value() {
  local v="${1:-}"
  if [[ ! "${v}" =~ ^[0-9]+$ ]] || (( v < 1 || v > 500 )); then
    die "invalid limit: ${v}"
  fi
  printf '%s' "${v}"
}
