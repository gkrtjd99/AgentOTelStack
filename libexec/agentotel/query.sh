#!/bin/sh
set -eu
. "$(dirname "$0")/common.sh"
command_name=${1:-}; shift || :
load_query_credential
query_dir="$ASSETS/obs"
[ -d "$query_dir" ] || query_dir="$RUNTIME_ROOT/obs"
[ -d "$query_dir" ] || die 'query helpers unavailable'

global=''; service=''; lookback=''; limit=''
case "$command_name" in
  services)
    while [ "$#" -gt 0 ]; do case "$1" in --global) global=--global; shift;; *) die 'usage: obs services [--global]';; esac; done
    exec "$query_dir/services.sh" ${global:+"$global"}
    ;;
  correlate)
    trace_id=''
    while [ "$#" -gt 0 ]; do case "$1" in --global) global=--global; shift;; --limit) limit=${2:?limit required}; shift 2;; --*) die 'usage: obs correlate [--global] TRACE_ID [--limit N]';; *) [ -z "$trace_id" ] || die 'multiple trace IDs'; trace_id=$1; shift;; esac; done
    [ -n "$trace_id" ] || die 'trace ID required'
    # The bounded helper currently fixes correlate at 100 items; retain that
    # public contract until the Gateway response schema exposes per-signal caps.
    [ -z "$limit" ] || [ "$limit" = 100 ] || die 'correlate limit must be 100'
    exec "$query_dir/correlate.sh" ${global:+"$global"} "$trace_id"
    ;;
  context|errors)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --global) global=--global; shift;;
        --service) service=${2:?service required}; shift 2;;
        --lookback) lookback=${2:?lookback required}; shift 2;;
        --limit) limit=${2:?limit required}; shift 2;;
        --*) die "usage: obs $command_name [--global] --service NAME [--lookback WINDOW] [--limit N]";;
        *) [ -z "$service" ] || die 'multiple services'; service=$1; shift;;
      esac
    done
    [ -n "$service" ] || die 'service required'
    lookback=${lookback:-15m}; limit=${limit:-50}
    if [ "$command_name" = context ]; then
      exec "$query_dir/context.sh" ${global:+"$global"} "$service" "$lookback" "$limit"
    fi
    exec "$query_dir/logs.sh" ${global:+"$global"} "$service" "$lookback" "$limit"
    ;;
  *) die 'invalid query command';;
esac
