#!/bin/sh
# Focused fixture for the CI gate inventory: comments do not count as gates,
# and the runtime trace must contain the complete required invocation sequence.
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
if false; then
  run_gate unreachable true
fi
run_gate present true
EOF
: >"$workflow_file"
python3 - "$local_file" "$workflow_file" "$bad_contract" "$good_contract" <<'PY'
import json
import pathlib
import sys

local, workflow, bad, good = map(pathlib.Path, sys.argv[1:])
base = {
    "version": 1,
    "local_script": str(local),
    "workflow": str(workflow),
    "required_hosted_step_names": [],
    "hosted_only_jobs": [],
}
for target, gates in ((bad, ["comment-only"]), (good, ["present"])):
    target.write_text(json.dumps({**base, "required_local_gates": gates}))
PY

if "$checker" "$bad_contract" >"$tmp/comment.out" 2>&1; then
  echo 'gate coverage accepted a comment-only gate' >&2
  exit 1
fi
grep -Fq 'missing executable local gate: comment-only' "$tmp/comment.out" || {
  echo 'gate coverage did not report the comment-only gate' >&2
  exit 1
}

printf '%s\n' present >"$tmp/good.trace"
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

echo 'CI gate coverage fixture: PASS (comments rejected and runtime trace enforced)'
