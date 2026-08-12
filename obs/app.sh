#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
cmd="${1:?usage: app.sh services|summary|logs|errors|traces|error-traces|metrics}"
case "$cmd" in
 services) exec "$(dirname "$0")/services.sh" ;;
 logs|errors) exec "$(dirname "$0")/logs.sh" "${2:-}" "${3:-15m}" "${4:-20}" ;;
 traces|error-traces) exec "$(dirname "$0")/traces.sh" search-errors "${2:-}" "${3:-20}" "${4:-1h}" ;;
 summary) exec "$(dirname "$0")/overview.sh" "${2:-sample-app}" "${3:-15m}" ;;
 metrics) exec "$(dirname "$0")/metrics.sh" "${2:-sample-app}" "15m" ;;
 operations) die "operations is deprecated; use services" ;;
 *) die "unknown subcommand: $cmd" ;;
esac
