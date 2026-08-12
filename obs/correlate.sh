#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"
[[ "${1:-}" != --soft ]] || shift
tid="${1:?usage: correlate.sh <traceID>}"
[[ "$tid" =~ ^[0-9a-f]{32}$ ]] || die "invalid trace id"
gateway_get /v1/correlate --data-urlencode "trace_id=${tid}" --data-urlencode "limit=100"
