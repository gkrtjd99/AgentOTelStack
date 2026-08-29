#!/bin/sh
# E2E command-contract fixture: verify Make's runner constructs the immutable
# npm/Playwright commands without claiming that a browser was launched. Real
# browser validation is performed separately by make e2e/e2e-app/e2e-dashboard.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/npm" <<'EOF'
#!/bin/sh
printf 'npm %s\n' "$*" >>"$FAKE_NPM_LOG"
[ -z "${TEST_WORKER_INDEX:-}" ] || { echo 'fake npm: caller-controlled worker marker reached install' >&2; exit 1; }
[ -z "${TEST_PARALLEL_INDEX:-}" ] || { echo 'fake npm: caller-controlled parallel marker reached install' >&2; exit 1; }
[ "${1:-}" = ci ] || { echo 'fake npm: only npm ci is permitted' >&2; exit 1; }
[ "${2:-}" = --ignore-scripts ] || exit 1
[ "${3:-}" = --no-audit ] || exit 1
exit 0
EOF
cat >"$tmp/bin/node" <<'EOF'
#!/bin/sh
printf 'node %s\n' "$*" >>"$FAKE_NPM_LOG"
[ -z "${TEST_WORKER_INDEX:-}" ] || {
  echo 'fake node: caller-controlled worker marker reached Playwright' >&2
  exit 1
}
[ -z "${TEST_PARALLEL_INDEX:-}" ] || {
  echo 'fake node: caller-controlled parallel marker reached Playwright' >&2
  exit 1
}
[ "${1:-}" = "$FAKE_PLAYWRIGHT_CLI" ] || {
  echo 'fake node: unexpected Playwright CLI path' >&2
  exit 1
}
case "${2:-}" in install|test) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$tmp/bin/npm" "$tmp/bin/node"

before=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
forged_proof="$tmp/forged-proof"
printf '%s\n' '{"version":2,"kind":"agentotel.e2e-ready.v2","mode":"all","dashboard_status":"ready","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","launcher_pid":'"$$"',"launcher_kind":"run-e2e","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$forged_proof"

# A forged proof and caller-controlled worker markers must not make direct
# helper/config execution look like a lifecycle-launched browser run.
if (
  exec 9<"$forged_proof"
  PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" \
    AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE=all \
    AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
    COMPOSE_PROJECT_NAME=agentotel-contract \
    "$root/scripts/run-browser-e2e.sh" all
) >"$tmp/direct-helper.out" 2>&1; then
  echo 'direct browser helper accepted a forged lifecycle capability' >&2
  exit 1
fi
grep -Fq 'readiness capability launcher' "$tmp/direct-helper.out"
[ ! -e "$tmp/npm.log" ] || { echo 'direct helper path installed dependencies' >&2; exit 1; }

if (
  cd "$root/e2e"
  AGENTOTEL_E2E_MODE=app TEST_WORKER_INDEX=1 \
    AGENTOTEL_E2E_READY_VERIFIED="$(printf '%064d' 0)" \
    node -e 'require("./playwright.config.js"); console.log("config-loaded")'
) >"$tmp/config-spoof.out" 2>&1; then
  echo 'caller-controlled worker markers bypassed Playwright readiness validation' >&2
  exit 1
fi
grep -Fq 'Direct npm E2E invocation is unsupported' "$tmp/config-spoof.out"

cat >"$tmp/lifecycle-runner.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
proof=$1
root=$2
printf '%s\n' '{"version":2,"kind":"agentotel.e2e-ready.v2","mode":"all","dashboard_status":"ready","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","launcher_pid":'"$$"',"launcher_kind":"run-e2e","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$proof"
exec 9<"$proof"
rm -f "$proof"
export AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE=all
export AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002
export COMPOSE_PROJECT_NAME=agentotel-contract
export APP_URL=http://127.0.0.1:3000 DASHBOARD_URL=http://127.0.0.1:3001
export DASHBOARD_E2E_AUTH_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
export DASHBOARD_BOOTSTRAP_URL="http://127.0.0.1:3001/#token=$DASHBOARD_E2E_AUTH_TOKEN"
"$root/scripts/run-browser-e2e.sh" all
EOF
chmod +x "$tmp/lifecycle-runner.sh"
(
  export PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" FAKE_PLAYWRIGHT_CLI="$root/e2e/node_modules/playwright/cli.js"
  export TEST_WORKER_INDEX=1 TEST_PARALLEL_INDEX=1
  bash -c 'exec -a "$1" bash "$2" "$3" "$4"' bash \
    "$root/scripts/run-e2e.sh" "$tmp/lifecycle-runner.sh" "$tmp/proof" "$root"
)

after=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
test "$before" = "$after" || { echo 'package-lock changed during fake E2E run' >&2; exit 1; }
grep -Fq 'npm ci --ignore-scripts --no-audit' "$tmp/npm.log"
grep -Fq "node $root/e2e/node_modules/playwright/cli.js install chromium" "$tmp/npm.log"
grep -Fq "node $root/e2e/node_modules/playwright/cli.js test" "$tmp/npm.log"
if grep -Fq 'npm install' "$tmp/npm.log"; then exit 1; fi
if grep -Fq 'npm run' "$tmp/npm.log"; then exit 1; fi

echo 'E2E command contract: PASS (inherited readiness capability; no browser launched; lock preservation verified)'
