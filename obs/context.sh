#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"; service="${1:-}"; gateway_get /v1/context --data-urlencode "service=${service}"
