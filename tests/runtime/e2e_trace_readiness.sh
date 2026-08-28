#!/usr/bin/env bash
# Exact trace readiness rejects supported-but-empty responses.
set -euo pipefail
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
trace=0123456789abcdef0123456789abcdef

cat >"$t/correlation-empty.json" <<EOF
{"kind":"correlate","partial":false,"data":{"supported":true,"trace_id":"$trace","spans":[],"logs":[],"metrics":[]}}
EOF
cat >"$t/errors-empty.json" <<EOF
{"kind":"errors","partial":false,"data":{"errors":[]}}
EOF
if "$root/scripts/check-trace-evidence.sh" "$trace" "$t/correlation-empty.json" "$t/errors-empty.json" >"$t/empty.out" 2>&1; then
  echo 'supported empty correlation was accepted' >&2
  exit 1
fi
grep -Fq 'supported response was empty' "$t/empty.out"

cat >"$t/correlation-complete.json" <<EOF
{"kind":"correlate","partial":false,"data":{"supported":true,"trace_id":"$trace","spans":[{"name":"checkout"}],"logs":[{"trace_id":"$trace"}],"metrics":[{"name":"checkout_total"}]}}
EOF
cat >"$t/errors-complete.json" <<EOF
{"kind":"errors","partial":false,"data":{"errors":[{"trace_id":"$trace","message":"forced failure"}]}}
EOF
"$root/scripts/check-trace-evidence.sh" "$trace" "$t/correlation-complete.json" "$t/errors-complete.json" >"$t/complete.out"
grep -Fq "trace evidence: complete trace=$trace" "$t/complete.out"

echo 'E2E trace readiness contract: PASS (supported-empty rejected; exact complete evidence accepted)'
