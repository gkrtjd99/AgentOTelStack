#!/bin/sh
set -eu
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
# Scrub retired Grafana variables before any ensure/help/Docker path can copy or
# inspect the inherited environment.
scrub_retired_grafana_env
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

# The bundled app and dashboard are the only Compose workloads that carry
# project provenance. Resolve it at invocation time so a checkout rekey is
# reflected immediately, and never silently fall back to a shared/stale
# identity. An explicit value is useful for a deliberately controlled
# non-Git invocation, but is held to the same UUIDv4 contract.
needs_demo_project=0
mark_project_profile(){
  case "$1" in
    demo|app|dashboard) needs_demo_project=1 ;;
  esac
}
mark_profile_list(){
  profile_list=$1
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  for profile in $profile_list; do
    profile=$(printf '%s' "$profile" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    mark_project_profile "$profile"
  done
  IFS=$old_ifs
}
mark_profile_list "${COMPOSE_PROFILES:-}"
# Bounded Compose argument scan. Values belonging to global options are never
# service selectors. Profiles are special: both separate and `=` forms are
# inspected, while app/dashboard are inspected only after a Compose command.
compose_skip=0
compose_skip_kind=''
compose_subcommand=0
for arg in "$@"; do
  if [ "$compose_skip" -eq 1 ]; then
    if [ "$compose_skip_kind" = profile ]; then mark_profile_list "$arg"; fi
    compose_skip=0
    compose_skip_kind=''
    continue
  fi
  case "$arg" in
    --profile)
      compose_skip=1
      compose_skip_kind=profile
      continue
      ;;
    --profile=*)
      mark_profile_list "${arg#--profile=}"
      continue
      ;;
    --env-file|-f|--file|-p|--project-name|--project-directory|--context|--log-level|--progress|--parallel|--ansi|--host|--tls-cacert|--tlscacert|--tlscert|--tlskey)
      compose_skip=1
      continue
      ;;
    --env-file=*|-f=*|--file=*|-p=*|--project-name=*|--project-directory=*|--context=*|--log-level=*|--progress=*|--parallel=*|--ansi=*|--host=*|--tls-cacert=*|--tlscacert=*|--tlscert=*|--tlskey=*)
      continue
      ;;
    # Boolean global options do not consume the next argument.
    --all-resources|--compatibility|--dry-run|--help|--no-ansi|--skip-hostname-check|--tls|--verbose)
      continue
      ;;
    --)
      compose_subcommand=1
      continue
      ;;
  esac
  if [ "$compose_subcommand" -eq 0 ]; then
    case "$arg" in
      build|config|cp|create|down|events|exec|images|kill|logs|pause|port|ps|pull|push|restart|rm|run|start|stats|stop|top|unpause|up|version|wait|watch)
        compose_subcommand=1
        ;;
      -*)
        # Unknown global options are left to Docker Compose. They cannot make a
        # pre-command app/dashboard token a service selector.
        ;;
    esac
  else
    case "$arg" in
      app|dashboard) mark_project_profile "$arg" ;;
    esac
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
