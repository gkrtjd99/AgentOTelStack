#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"
json=0; service="sample-app"; lookback="15m"
while [[ $# -gt 0 ]]; do case "$1" in --global) export AGENTOTEL_GLOBAL=1;;--json)json=1;;--compact) ;;--lookback|--since)shift;lookback="$1";;-*)die "unknown option: $1";;*)service="$1";;esac;shift;done
duration_value "$lookback" >/dev/null
if ((json)); then gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}"; else gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}" | pp; fi
