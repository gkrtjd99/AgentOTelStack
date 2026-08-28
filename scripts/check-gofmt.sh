#!/bin/sh
# Run gofmt without masking formatter failures behind command substitution.
set -eu

[ "$#" -eq 1 ] || {
  echo "usage: $0 GO-DIRECTORY" >&2
  exit 2
}
directory=$1
[ -d "$directory" ] || {
  echo "gofmt-check: directory not found: $directory" >&2
  exit 2
}
formatter=${GOFMT_BIN:-gofmt}
tmp=$(mktemp "${TMPDIR:-/tmp}/agentotel-gofmt.XXXXXX")
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM

set +e
(
  cd "$directory" || exit
  "$formatter" -d -e .
) >"$tmp" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  cat "$tmp" >&2
  echo "gofmt-check: formatter failed with status $status" >&2
  exit "$status"
fi
if [ -s "$tmp" ]; then
  cat "$tmp"
  echo "gofmt-check: source is not formatted" >&2
  exit 1
fi
