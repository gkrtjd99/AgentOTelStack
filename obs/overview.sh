#!/usr/bin/env bash
global=0; [[ "${1:-}" == --global ]] && { global=1; shift; }
(( global )) && export AGENTOTEL_GLOBAL=1
source "$(dirname "$0")/common.sh"
json=0; compact=0; service="sample-app"; lookback="15m"
positional_count=0; lookback_set=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --global)
      export AGENTOTEL_GLOBAL=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    --compact)
      compact=1
      shift
      ;;
    --lookback|--since)
      [[ $# -ge 2 && -n "${2:-}" && "${2}" != --* ]] || die "$1 requires a value"
      (( lookback_set == 0 )) || die "lookback specified more than once"
      lookback="$2"
      lookback_set=1
      shift 2
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      (( positional_count < 2 )) || die "too many positional arguments"
      if (( positional_count == 0 )); then
        service="$1"
      else
        (( lookback_set == 0 )) || die "lookback specified more than once"
        lookback="$1"
        lookback_set=1
      fi
      positional_count=$((positional_count + 1))
      shift
      ;;
  esac
done
(( json == 0 || compact == 0 )) || die "--json and --compact cannot be combined"
duration_value "$lookback" >/dev/null

if (( json )); then
  gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}"
elif (( compact )); then
  gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}" | pp -c
else
  gateway_get /v1/context --data-urlencode "service=${service}" --data-urlencode "lookback=${lookback}" | pp
fi
