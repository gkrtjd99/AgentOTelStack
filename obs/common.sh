#!/usr/bin/env bash
# Shared config for the obs/* query helpers. Sourced, not run directly.
# All reads go through the local query Gateway.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:17777}"
if [[ -z "${GATEWAY_QUERY_TOKEN:-}" && -n "${GATEWAY_QUERY_TOKEN_FILE:-}" && -r "${GATEWAY_QUERY_TOKEN_FILE}" ]]; then GATEWAY_QUERY_TOKEN="$(<"${GATEWAY_QUERY_TOKEN_FILE}")"; fi
if [[ -z "${GATEWAY_QUERY_TOKEN:-}" ]]; then die "GATEWAY_QUERY_TOKEN is required"; fi
gateway_get() { curl -fsS -H "Authorization: Bearer ${GATEWAY_QUERY_TOKEN}" --get "${GATEWAY_URL}${1}" "${@:2}"; }

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
