#!/bin/sh
# Regression fixture for function-backed CI gates: a failing command must stop
# the child gate process even when the parent continues to later gates.
set -eu
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-gate-runner.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat >"$tmp/gate.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
probe() {
  false
  printf 'unreachable\n'
}
probe
EOF
chmod +x "$tmp/gate.sh"
if bash "$tmp/gate.sh" >"$tmp/output" 2>&1; then
  echo 'strict child gate unexpectedly succeeded after a failed command' >&2
  exit 1
fi
if grep -Fq unreachable "$tmp/output"; then
  echo 'strict child gate continued after a failed command' >&2
  exit 1
fi

# The conditional-subshell anti-pattern is intentionally rejected: it makes
# Bash ignore errexit inside the function body.
cat >"$tmp/conditional.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
probe() {
  false
  printf 'unreachable\n'
}
if ( set -Eeuo pipefail; probe ); then
  exit 0
fi
EOF
if ! bash "$tmp/conditional.sh" >"$tmp/conditional-output" 2>&1; then
  echo 'conditional subshell did not reproduce the masking behavior' >&2
  exit 1
fi
grep -Fq unreachable "$tmp/conditional-output"

echo 'CI local gate errexit fixture: PASS (fresh child preserves function failure)'
