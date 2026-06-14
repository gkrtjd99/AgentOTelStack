#!/usr/bin/env bash
# Query traces from VictoriaTraces via its Jaeger-compatible query API.
# (VictoriaTraces has no native TraceQL as of 2026 — it speaks the Jaeger query API.)
#
# Usage:
#   obs/traces.sh services                         # list known service names
#   obs/traces.sh operations <service>             # list operations for a service
#   obs/traces.sh search <service> [limit] [lookback]   # recent traces (default 20, 1h)
#   obs/traces.sh search-errors <service> [limit] [lookback]  # recent ERROR traces only
#   obs/traces.sh search <service> --limit 20 --lookback 1h
#   obs/traces.sh search-errors <service> --limit 5 --since 15m
#   obs/traces.sh get <traceID>                    # full trace by id
#
# Examples:
#   obs/traces.sh services
#   obs/traces.sh search sample-app 20 1h
#   obs/traces.sh search-errors sample-app
#   obs/traces.sh get 7f3a2b...
#
# Docs: https://docs.victoriametrics.com/victoriatraces/querying/

source "$(dirname "$0")/common.sh"

base="${VT_URL}/select/jaeger/api"
cmd="${1:?usage: traces.sh services|operations|search|search-errors|get ...}"

parse_search_args() {
  svc="${1:?usage: traces.sh ${cmd} <service> [limit] [lookback]}"
  shift

  limit="20"
  lookback="1h"
  positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        shift
        [[ $# -gt 0 ]] || die "--limit requires a value"
        limit="$(limit_value "$1")"
        ;;
      --lookback|--since)
        opt="$1"
        shift
        [[ $# -gt 0 ]] || die "${opt} requires a value"
        lookback="$(duration_value "$1")"
        ;;
      --*)
        die "unknown option for ${cmd}: $1"
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if [[ ${#positional[@]} -gt 0 ]]; then
    limit="$(limit_value "${positional[0]}")"
  fi
  if [[ ${#positional[@]} -gt 1 ]]; then
    lookback="$(duration_value "${positional[1]}")"
  fi
  if [[ ${#positional[@]} -gt 2 ]]; then
    die "too many positional arguments for ${cmd}"
  fi
}

case "$cmd" in
  services)
    curl -s "${base}/services" | pp '.data'
    ;;
  operations)
    svc="${2:?usage: traces.sh operations <service>}"
    curl -s "${base}/operations" --data-urlencode "service=${svc}" -G | pp '.data'
    ;;
  search)
    shift
    parse_search_args "$@"
    curl -s "${base}/traces" -G \
      --data-urlencode "service=${svc}" \
      --data-urlencode "limit=${limit}" \
      --data-urlencode "lookback=${lookback}" | pp
    ;;
  search-errors)
    shift
    parse_search_args "$@"
    curl -s "${base}/traces" -G \
      --data-urlencode "service=${svc}" \
      --data-urlencode "limit=${limit}" \
      --data-urlencode "lookback=${lookback}" \
      --data-urlencode "tags={\"error\":\"true\"}" | pp
    ;;
  get)
    tid="${2:?usage: traces.sh get <traceID>}"
    curl -s "${base}/traces/${tid}" | pp
    ;;
  *)
    die "unknown subcommand: $cmd"
    ;;
esac
