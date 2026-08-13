#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"
[[ $# -le 3 ]] || die "usage: logs.sh [service] [lookback] [limit]"
service="${1:-}"; lookback="${2:-15m}"; limit="${3:-20}"
duration_value "$lookback" >/dev/null; limit_value "$limit" >/dev/null
gateway_get /v1/errors --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}" --data-urlencode "limit=${limit}"
