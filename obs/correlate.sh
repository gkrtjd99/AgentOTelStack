#!/usr/bin/env bash
# Correlate a single trace across all three signals — the core agent move.
# Given a trace_id, fetch its spans (VictoriaTraces) AND every log line that
# carries that trace_id (VictoriaLogs). This is how an agent goes from
# "something is slow/broken" to "here is the exact code path + log context".
#
# Usage:
#   obs/correlate.sh <traceID> [logs-lookback]
#
# Example:
#   obs/correlate.sh 7f3a2b9c... 1h

source "$(dirname "$0")/common.sh"

tid="${1:?usage: correlate.sh <traceID> [logs-lookback]}"
lookback="${2:-1h}"

echo "=== TRACE ${tid} ==="
curl -s "${VT_URL}/select/jaeger/api/traces/${tid}" | pp '.data[0].spans[] | {op: .operationName, durMs: (.duration/1000), tags: ([.tags[] | select(.key=="error" or .key=="http.status_code")])}' 2>/dev/null \
  || curl -s "${VT_URL}/select/jaeger/api/traces/${tid}" | pp

echo
echo "=== LOGS with trace_id=${tid} (last ${lookback}) ==="
curl -s "${VL_URL}/select/logsql/query" \
  --data-urlencode "query=_time:${lookback} trace_id:${tid}" \
  --data-urlencode "limit=100"
