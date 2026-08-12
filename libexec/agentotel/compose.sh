#!/bin/sh
set -eu
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
usage(){
  cat >&2 <<'EOF'
usage: obs compose <docker compose arguments>
compose config and convert are disabled because they render credential values;
use make doctor or another non-rendering Compose operation instead.
EOF
  exit 2
}
[ "$#" -gt 0 ] || usage
command -v docker >/dev/null 2>&1 || die 'docker is unavailable'
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
  printf '%s\n' 'agentotel: compose config and convert are disabled because they render credential values.'
  exec docker compose --help
fi
for arg in "$@"; do
  case "$arg" in
    config|convert) die "compose $arg is disabled because it renders credential values; use make doctor or a non-rendering Compose operation" 2;;
  esac
done
"$(dirname "$0")/credentials.sh" ensure >/dev/null
. "$(dirname "$0")/common.sh"
if [ -z "${GATEWAY_INGEST_TOKEN:-}" ] || [ -z "${GATEWAY_QUERY_TOKEN:-}" ] || [ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]; then
  die 'credentials incomplete; run obs credentials rotate'
fi
# common.sh has already loaded and validated all three values.  Keep this as
# an exec so secrets are present only in the child environment, never in an
# echoed command line or a generated .env file.
exec docker compose "$@"
