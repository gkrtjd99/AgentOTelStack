#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
cmd="${1:?usage: traces.sh services|search|search-errors|get}"
case "$cmd" in
 services) gateway_get /v1/services ;;
 search|search-errors) service="${2:?service required}";limit="${3:-20}";lookback="${4:-1h}";limit_value "$limit" >/dev/null;duration_value "$lookback" >/dev/null;gateway_get /v1/errors --data-urlencode "service=${service}" --data-urlencode "limit=${limit}" --data-urlencode "lookback=${lookback}" ;;
 get) tid="${2:?trace id required}";gateway_get /v1/correlate --data-urlencode "trace_id=${tid}" ;;
 operations) die "operations is deprecated; use services" ;;
 *) die "unknown subcommand: $cmd" ;;
esac
