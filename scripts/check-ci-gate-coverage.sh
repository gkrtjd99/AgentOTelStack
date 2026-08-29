#!/bin/sh
# Validate the machine-readable local/hosted CI gate inventory.
set -eu
root=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
contract="$root/tests/ci_gate_coverage.json"
trace=''
contract_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trace)
      [ "$#" -ge 2 ] || { echo 'usage: check-ci-gate-coverage.sh [--trace FILE] [CONTRACT]' >&2; exit 2; }
      trace=$2
      shift 2
      ;;
    --)
      shift
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      [ "$contract_set" -eq 0 ] || { echo 'only one CI gate coverage contract is allowed' >&2; exit 2; }
      contract=$1
      contract_set=1
      shift
      ;;
  esac
done
python3 - "$root" "$contract" "$trace" <<'PY'
import json
import pathlib
import re
import shlex
import sys
from collections import Counter

root = pathlib.Path(sys.argv[1])
contract_path = pathlib.Path(sys.argv[2])
trace_path = pathlib.Path(sys.argv[3]) if sys.argv[3] else None
data = json.loads(contract_path.read_text())
if data.get("version") != 2:
    raise SystemExit("CI gate coverage: unsupported contract version")
local = (root / data["local_script"]).read_text()
workflow = (root / data["workflow"]).read_text()
errors = []
required = data.get("required_local_gates", [])

def invocation(item, source):
    if not isinstance(item, dict) or not isinstance(item.get("name"), str):
        errors.append(f"invalid {source} gate entry: expected an object with a name")
        return None
    argv = item.get("argv")
    if not isinstance(argv, list) or not all(isinstance(value, str) for value in argv):
        errors.append(f"invalid {source} gate entry {item['name']!r}: argv must be a string list")
        return None
    if not argv:
        errors.append(f"invalid {source} gate entry {item['name']!r}: argv must not be empty")
        return None
    return (item["name"], tuple(argv))

required_invocations = [
    value for value in (invocation(item, "contract") for item in required) if value is not None
]
if len(required_invocations) != len(required):
    required_invocations = []

gate_re = re.compile(r"^[ \t]*run_gate(?:[ \t]+|$)")
declared = []
for line_number, line in enumerate(local.splitlines(), 1):
    if not gate_re.match(line):
        continue
    try:
        tokens = shlex.split(line, comments=True, posix=True)
    except ValueError as exc:
        errors.append(f"cannot parse local gate line {line_number}: {exc}")
        continue
    if len(tokens) < 3 or tokens[0] != "run_gate":
        errors.append(f"local gate line {line_number} has no gate name and command argv")
        continue
    declared.append((tokens[1], tuple(tokens[2:])))

expected_counts = Counter(required_invocations)
declared_counts = Counter(declared)
if declared_counts != expected_counts:
    missing = list((expected_counts - declared_counts).elements())
    unexpected = list((declared_counts - expected_counts).elements())
    errors.append(
        "declared local gate invocations differ: "
        f"missing {missing!r}, unexpected {unexpected!r}"
    )

if trace_path is not None:
    observed = []
    try:
        trace_lines = trace_path.read_text().splitlines()
    except OSError as exc:
        errors.append(f"local gate invocation trace unavailable: {exc}")
    else:
        for line_number, line in enumerate(trace_lines, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append(f"invalid runtime gate trace line {line_number}: {exc.msg}")
                continue
            if item.get("status") not in {"pass", "fail"}:
                errors.append(
                    f"invalid runtime gate trace line {line_number}: "
                    "status must be pass or fail"
                )
            value = invocation(item, "runtime trace")
            if value is not None:
                observed.append(value)
        observed_counts = Counter(observed)
        if observed_counts != expected_counts:
            missing = list((expected_counts - observed_counts).elements())
            unexpected = list((observed_counts - expected_counts).elements())
            errors.append(
                "runtime local gate invocations differ: "
                f"missing {missing!r}, unexpected {unexpected!r}"
            )

for step in data.get("required_hosted_step_names", []):
    if not re.search(r"^\s*- name:\s*" + re.escape(step) + r"\s*$", workflow, re.M):
        errors.append(f"missing hosted step: {step}")
for job in data.get("hosted_only_jobs", []):
    if not re.search(r"^\s{2}" + re.escape(job) + r":\s*$", workflow, re.M):
        errors.append(f"missing hosted-only job: {job}")
if errors:
    print("CI gate coverage: FAIL", file=sys.stderr)
    print("\n".join(f" - {error}" for error in errors), file=sys.stderr)
    raise SystemExit(1)
trace_note = ", runtime invocations verified" if trace_path is not None else ""
print(f"CI gate coverage: PASS ({len(required_invocations)} local gates, {len(data.get('required_hosted_step_names', []))} hosted steps{trace_note})")
PY
