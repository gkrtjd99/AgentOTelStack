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
import sys
from collections import Counter

root = pathlib.Path(sys.argv[1])
contract_path = pathlib.Path(sys.argv[2])
trace_path = pathlib.Path(sys.argv[3]) if sys.argv[3] else None
data = json.loads(contract_path.read_text())
if data.get("version") != 1:
    raise SystemExit("CI gate coverage: unsupported contract version")
local = (root / data["local_script"]).read_text()
workflow = (root / data["workflow"]).read_text()
errors = []
required_gates = data.get("required_local_gates", [])
# Only an executable-looking, line-anchored invocation counts. This prevents a
# comment or an arbitrary string from satisfying the static inventory; the
# optional trace below proves that each listed line was actually reached.
gate_re = re.compile(r"^[ \t]*run_gate[ \t]+([A-Za-z0-9][A-Za-z0-9_-]*)(?:[ \t]|$)")
declared_gates = []
for line in local.splitlines():
    code = line.split("#", 1)[0]
    match = gate_re.match(code)
    if match:
        declared_gates.append(match.group(1))
for gate in required_gates:
    if gate not in declared_gates:
        errors.append(f"missing executable local gate: {gate}")
if trace_path is not None:
    try:
        observed_gates = [line.strip() for line in trace_path.read_text().splitlines() if line.strip()]
    except OSError as exc:
        errors.append(f"local gate invocation trace unavailable: {exc}")
    else:
        expected_counts = Counter(required_gates)
        observed_counts = Counter(observed_gates)
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
print(f"CI gate coverage: PASS ({len(required_gates)} local gates, {len(data.get('required_hosted_step_names', []))} hosted steps{trace_note})")
PY
