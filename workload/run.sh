#!/usr/bin/env bash
# Workload runner — generates realistic traffic against the app so the
# observability stack fills with logs/metrics/traces. Run it after the stack
# is up; let an agent re-run it after a code change to compare before/after.
#
# Usage:
#   workload/run.sh [requests] [base_url]
#
# Examples:
#   workload/run.sh            # 200 requests against localhost:3000
#   workload/run.sh 1000
#   workload/run.sh 500 http://localhost:3000

set -euo pipefail

total="${1:-200}"
base="${2:-http://localhost:3000}"

echo "→ sending ${total} requests to ${base}"
for i in $(seq 1 "${total}"); do
  r=$((RANDOM % 10))
  if   [[ $r -lt 5 ]]; then path="/api/orders/$((RANDOM % 1000))"
  elif [[ $r -lt 9 ]]; then path="/api/checkout"
  else                     path="/api/checkout?fail=1"   # ~10% forced failures
  fi
  curl -s -o /dev/null -w "%{http_code} ${path}\n" "${base}${path}" || true
  # light pacing so spans spread over time
  sleep 0.05
done
echo "→ done. Query it: ./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'"
