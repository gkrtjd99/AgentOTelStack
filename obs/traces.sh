#!/usr/bin/env bash
# Query traces from VictoriaTraces via its Jaeger-compatible query API.
# (VictoriaTraces has no native TraceQL as of 2026 — it speaks the Jaeger query API.)
#
# Usage:
#   obs/traces.sh services                         # list known service names
#   obs/traces.sh operations <service>             # list operations for a service
#   obs/traces.sh search <service> [limit] [lookback]   # recent traces (default 20, 1h)
#   obs/traces.sh search-errors <service> [limit]  # recent ERROR traces only
#   obs/traces.sh get <traceID>                    # full trace by id
#
# Examples:
#   obs/traces.sh services
#   obs/traces.sh search sample-app 20 1h
#   obs/traces.sh search-errors sample-app
#   obs/traces.sh get 7f3a2b...
#
# Docs: https://docs.victoriametrics.com/victoriatraces/querying/

source "$(dirname "$0")/common.sh"

base="${VT_URL}/select/jaeger/api"
cmd="${1:?usage: traces.sh services|operations|search|search-errors|get ...}"

case "$cmd" in
  services)
    curl -s "${base}/services" | pp '.data'
    ;;
  operations)
    svc="${2:?usage: traces.sh operations <service>}"
    curl -s "${base}/operations" --data-urlencode "service=${svc}" -G | pp '.data'
    ;;
  search)
    svc="${2:?usage: traces.sh search <service> [limit] [lookback]}"
    limit="${3:-20}"; lookback="${4:-1h}"
    curl -s "${base}/traces" -G \
      --data-urlencode "service=${svc}" \
      --data-urlencode "limit=${limit}" \
      --data-urlencode "lookback=${lookback}" | pp
    ;;
  search-errors)
    svc="${2:?usage: traces.sh search-errors <service> [limit]}"
    limit="${3:-20}"
    curl -s "${base}/traces" -G \
      --data-urlencode "service=${svc}" \
      --data-urlencode "limit=${limit}" \
      --data-urlencode "lookback=1h" \
      --data-urlencode "tags={\"error\":\"true\"}" | pp
    ;;
  get)
    tid="${2:?usage: traces.sh get <traceID>}"
    curl -s "${base}/traces/${tid}" | pp
    ;;
  *)
    die "unknown subcommand: $cmd"
    ;;
esac
