#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"; gateway_get /v1/services
