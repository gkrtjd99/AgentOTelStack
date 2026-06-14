#!/usr/bin/env bash
# Query logs from VictoriaLogs with LogQL.
#
# Usage:
#   obs/logs.sh '<LogQL query>' [limit]
#
# Examples:
#   obs/logs.sh '_time:5m severity_text:error'         # recent errors
#   obs/logs.sh '_time:15m service.name:sample-app' 50
#   obs/logs.sh '_time:1h trace_id:abc123...'          # logs for a trace
#
# Note: OTLP logs use the field `severity_text` (info/warn/error), not `level`.
#
# Returns newline-delimited JSON log records. Pipe to jq for shaping.
# Docs: https://docs.victoriametrics.com/victorialogs/logsql/

source "$(dirname "$0")/common.sh"

query="${1:-_time:5m *}"
limit="$(limit_value "${2:-20}")"

curl -s "${VL_URL}/select/logsql/query" \
  --data-urlencode "query=${query}" \
  --data-urlencode "limit=${limit}"
