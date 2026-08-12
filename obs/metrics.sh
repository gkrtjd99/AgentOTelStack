#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"
[[ $# -le 3 ]] || die "usage: metrics.sh [service] [lookback] [range]"
service="${1:-sample-app}"; lookback="${2:-15m}"; duration_value "$lookback" >/dev/null
[[ -z "${3:-}" || "${3}" == range ]] || die "raw PromQL is deprecated; use service/lookback"
gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}"
