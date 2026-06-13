#!/usr/bin/env bash
# Shared config for the obs/* query helpers. Sourced, not run directly.
# Override any host via env, e.g. VL_URL=http://remote:9428 ./obs/logs.sh ...

set -euo pipefail

VL_URL="${VL_URL:-http://localhost:9428}"   # VictoriaLogs  (LogQL)
VM_URL="${VM_URL:-http://localhost:8428}"   # VictoriaMetrics (PromQL)
VT_URL="${VT_URL:-http://localhost:10428}"  # VictoriaTraces (Jaeger query)

# Pretty-print JSON if jq exists, otherwise pass through.
pp() { if command -v jq >/dev/null 2>&1; then jq "${1:-.}"; else cat; fi; }

die() { echo "error: $*" >&2; exit 1; }
