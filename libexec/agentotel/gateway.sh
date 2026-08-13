#!/bin/sh
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
base=${AGENTOTEL_GATEWAY_URL:-http://127.0.0.1:4318}; timeout=${AGENTOTEL_TIMEOUT:-3}
gateway(){
 command -v curl >/dev/null 2>&1 || die gateway_unavailable 69
 out=$(curl -fsS --max-time "$timeout" "$base/v1/version" 2>/dev/null) || die gateway_unavailable 69
 printf '%s' "$out" | grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+"' || die gateway_malformed 65
 vals=$(printf '%s' "$out" | awk 'BEGIN{n=0} {if(match($0,/"api_min"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+"/))n++; if(match($0,/"api_max"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+"/))n++} END{print n}')
 [ "$vals" = 2 ] || die gateway_malformed 65
 server_min=$(printf '%s' "$out" | sed -n 's/.*"api_min"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p'); server_max=$(printf '%s' "$out" | sed -n 's/.*"api_max"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p')
 client=${AGENTOTEL_API_VERSION:-1.0}; cmajor=${client%%.*}; minmajor=${server_min%%.*}; maxmajor=${server_max%%.*}
 if ! { [ "$cmajor" -ge "$minmajor" ] && [ "$cmajor" -le "$maxmajor" ]; } 2>/dev/null; then die gateway_incompatible 78; fi
 if [ -n "${AGENTOTEL_REQUIRED_CAPABILITY:-}" ]; then printf '%s' "$out" | grep -q "${AGENTOTEL_REQUIRED_CAPABILITY}" || die gateway_incompatible 78; fi
 printf '%s\n' "$out"
}
gateway
