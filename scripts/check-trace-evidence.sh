#!/usr/bin/env bash
# Validate that one exact forced trace has complete, non-empty evidence.
set -Eeuo pipefail

if (( $# != 3 )); then
  echo 'usage: check-trace-evidence.sh TRACE_ID CORRELATION_JSON ERRORS_JSON' >&2
  exit 2
fi
trace=$1
correlation_file=$2
errors_file=$3
[[ "$trace" =~ ^[0-9a-f]{32}$ ]] || { echo 'trace evidence: invalid trace ID' >&2; exit 1; }
[[ -f "$correlation_file" && -f "$errors_file" ]] || { echo 'trace evidence: response file missing' >&2; exit 1; }

if ! jq -n -e --arg trace "$trace" --slurpfile correlation "$correlation_file" --slurpfile errors "$errors_file" '
  ($correlation[0]) as $c |
  ($errors[0]) as $e |
  [
    ($c.kind == "correlate"),
    ($c.partial == false),
    ($c.data.supported == true),
    ($c.data.trace_id == $trace),
    (($c.data.spans // []) | length > 0),
    (($c.data.logs // []) | length > 0),
    (($c.data.metrics // []) | length > 0),
    ([($c.data.logs // [])[] | select(.trace_id == $trace)] | length > 0),
    ($e.kind == "errors"),
    ($e.partial == false),
    ([($e.data.errors // [])[] | select(.trace_id == $trace)] | length > 0)
  ] | all
' >/dev/null 2>&1; then
  echo 'trace evidence: supported response was empty or lacked exact error evidence' >&2
  exit 1
fi
printf 'trace evidence: complete trace=%s\n' "$trace"
