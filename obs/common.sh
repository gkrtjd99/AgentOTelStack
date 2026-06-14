#!/usr/bin/env bash
# Shared config for the obs/* query helpers. Sourced, not run directly.
# Override any host via env, e.g. VL_URL=http://remote:9428 ./obs/logs.sh ...

set -euo pipefail

VL_URL="${VL_URL:-http://localhost:9428}"   # VictoriaLogs  (LogQL)
VM_URL="${VM_URL:-http://localhost:8428}"   # VictoriaMetrics (PromQL)
VT_URL="${VT_URL:-http://localhost:10428}"  # VictoriaTraces (Jaeger query)

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
  if [[ ! "${v}" =~ ^[0-9]+(ms|s|m|h|d|w|y)$ ]]; then
    die "invalid duration: ${v}"
  fi
  printf '%s' "${v}"
}

limit_value() {
  local v="${1:-}"
  if [[ ! "${v}" =~ ^[0-9]+$ ]] || (( v < 1 || v > 1000 )); then
    die "invalid limit: ${v}"
  fi
  printf '%s' "${v}"
}

die() { echo "error: $*" >&2; exit 1; }
