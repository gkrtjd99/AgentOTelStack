#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
scope_args=(); (( global )) && scope_args=(--global)
source "$(dirname "$0")/common.sh"
cmd="${1:?usage: app.sh services|summary|logs|errors|traces|error-traces|metrics}"
shift
case "$cmd" in
  services) exec "$(dirname "$0")/services.sh" "${scope_args[@]}" ;;
  logs|errors) exec "$(dirname "$0")/logs.sh" "${scope_args[@]}" "${1:-}" "${2:-15m}" "${3:-20}" ;;
  traces|error-traces) exec "$(dirname "$0")/traces.sh" "${scope_args[@]}" search-errors "${1:-}" "${2:-20}" "${3:-1h}" ;;
  summary) exec "$(dirname "$0")/overview.sh" "${scope_args[@]}" --lookback "${2:-15m}" "${1:-sample-app}" ;;
  metrics) exec "$(dirname "$0")/metrics.sh" "${scope_args[@]}" "${1:-sample-app}" "15m" ;;
 operations) die "operations is deprecated; use services" ;;
 *) die "unknown subcommand: $cmd" ;;
esac
