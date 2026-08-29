#!/bin/sh
# Focused fixture for the CI gate inventory: comments do not count as gates,
# and source/runtime records must contain the exact gate command argv.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
checker="$root/scripts/check-ci-gate-coverage.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-gate-coverage.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

local_file="$tmp/local.sh"
workflow_file="$tmp/workflow.yml"
bad_contract="$tmp/bad.json"
good_contract="$tmp/good.json"
cat >"$local_file" <<'EOF'
# run_gate comment-only true
run_gate present true
EOF
: >"$workflow_file"
python3 - "$local_file" "$workflow_file" "$bad_contract" "$good_contract" <<'PY'
import json
import pathlib
import sys

local, workflow, bad, good = map(pathlib.Path, sys.argv[1:])
base = {
    "version": 2,
    "local_script": str(local),
    "workflow": str(workflow),
    "required_hosted_step_names": [],
    "hosted_only_jobs": [],
}
bad.write_text(json.dumps({
    **base,
    "required_local_gates": [{"name": "comment-only", "argv": ["true"]}],
}))
good.write_text(json.dumps({
    **base,
    "required_local_gates": [{"name": "present", "argv": ["true"]}],
}))
PY

if "$checker" "$bad_contract" >"$tmp/comment.out" 2>&1; then
  echo 'gate coverage accepted a comment-only gate' >&2
  exit 1
fi
grep -Fq 'declared local gate invocations differ' "$tmp/comment.out" || {
  echo 'gate coverage did not report the comment-only gate' >&2
  exit 1
}

printf '%s\n' '{"name":"present","argv":["true"],"status":"pass"}' >"$tmp/good.trace"
"$checker" --trace "$tmp/good.trace" "$good_contract" >/dev/null
: >"$tmp/empty.trace"
if "$checker" --trace "$tmp/empty.trace" "$good_contract" >"$tmp/trace.out" 2>&1; then
  echo 'gate coverage accepted an empty invocation trace' >&2
  exit 1
fi
grep -Fq 'runtime local gate invocations differ' "$tmp/trace.out" || {
  echo 'gate coverage did not report the missing runtime invocation' >&2
  exit 1
}

printf '%s\n' '{"name":"present","argv":["false"],"status":"fail"}' >"$tmp/wrong-argv.trace"
if "$checker" --trace "$tmp/wrong-argv.trace" "$good_contract" >"$tmp/wrong-argv.out" 2>&1; then
  echo 'gate coverage accepted a wrong command argv' >&2
  exit 1
fi
grep -Fq 'runtime local gate invocations differ' "$tmp/wrong-argv.out"

printf '%s\n' \
  '{"name":"present","argv":["true"],"status":"pass"}' \
  '{"name":"present","argv":["true"],"status":"pass"}' >"$tmp/duplicate.trace"
if "$checker" --trace "$tmp/duplicate.trace" "$good_contract" >"$tmp/duplicate.out" 2>&1; then
  echo 'gate coverage accepted a duplicate runtime invocation' >&2
  exit 1
fi
grep -Fq 'runtime local gate invocations differ' "$tmp/duplicate.out"

printf '%s\n' '{"name":"unexpected","argv":["true"],"status":"pass"}' >"$tmp/unexpected.trace"
if "$checker" --trace "$tmp/unexpected.trace" "$good_contract" >"$tmp/unexpected.out" 2>&1; then
  echo 'gate coverage accepted an unexpected runtime invocation' >&2
  exit 1
fi
grep -Fq 'runtime local gate invocations differ' "$tmp/unexpected.out"

printf '%s\n' '{not-json}' >"$tmp/malformed.trace"
if "$checker" --trace "$tmp/malformed.trace" "$good_contract" >"$tmp/malformed.out" 2>&1; then
  echo 'gate coverage accepted malformed runtime trace JSON' >&2
  exit 1
fi
grep -Fq 'invalid runtime gate trace line' "$tmp/malformed.out"

echo 'CI gate coverage fixture: PASS (comments, argv drift, duplicates, and malformed traces rejected)'
