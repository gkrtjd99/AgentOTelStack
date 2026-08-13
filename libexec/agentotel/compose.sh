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
"$(dirname "$0")/credentials.sh" ensure >/dev/null
. "$(dirname "$0")/common.sh"
load_compose_credentials

# The bundled app is the only Compose workload that carries project
# provenance.  Resolve it at invocation time so a checkout rekey is reflected
# immediately, and never silently fall back to a shared/stale identity.  An
# explicit value is useful for a deliberately controlled non-Git invocation,
# but is held to the same UUIDv4 contract.
needs_demo_project=0
profile_arg=0
for arg in "$@"; do
  case "$arg" in
    --profile) profile_arg=1; continue ;;
    --profile=demo|app) needs_demo_project=1 ;;
  esac
  if [ "$profile_arg" -eq 1 ]; then
    [ "$arg" = demo ] && needs_demo_project=1
    profile_arg=0
  fi
done
if [ "$needs_demo_project" -eq 1 ]; then
  if [ -n "${AGENTOTEL_PROJECT_ID:-}" ]; then
    valid_project_uuid "$AGENTOTEL_PROJECT_ID" || die 'AGENTOTEL_PROJECT_ID must be a UUIDv4'
  else
    AGENTOTEL_PROJECT_ID=$("$(dirname "$0")/project.sh" ensure) || die 'unable to resolve workspace project UUID'
    valid_project_uuid "$AGENTOTEL_PROJECT_ID" || die 'workspace project is not a UUIDv4'
  fi
  export AGENTOTEL_PROJECT_ID
fi
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
  printf '%s\n' 'agentotel: compose config and convert are disabled because they render credential values.'
  exec docker compose --help
fi
for arg in "$@"; do
  case "$arg" in
    config|convert) die "compose $arg is disabled because it renders credential values; use make doctor or a non-rendering Compose operation" 2;;
  esac
done
# common.sh has already loaded and validated all three values.  Keep this as
# an exec so secrets are present only in the child environment, never in an
# echoed command line or a generated .env file.
exec docker compose "$@"
