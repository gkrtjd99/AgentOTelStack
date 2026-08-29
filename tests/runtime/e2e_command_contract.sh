#!/bin/sh
# E2E command-contract fixture: verify the real source-only lifecycle helper
# constructs immutable npm/Playwright commands without claiming browser proof.
# Real browser validation is performed separately by make e2e/e2e-app/e2e-dashboard.
set -eu
repo_root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
lifecycle_source=". \"\$ROOT/scripts/run-browser-e2e.sh\""
all_helper_call="run_browser_e2e \"\$mode\" \"\$ready_proof_file\""
ci_helper_call="run_browser_e2e all \"\$ready_proof_file\""

# The supported lifecycle scripts must own the source call site; the positive
# fixture below is only an explicitly allowlisted command-contract caller.
grep -Fq "$lifecycle_source" "$repo_root/scripts/run-e2e.sh"
grep -Fq "$lifecycle_source" "$repo_root/scripts/test-ci-integration.sh"
grep -Fq "$all_helper_call" "$repo_root/scripts/run-e2e.sh"
grep -Fq "$ci_helper_call" "$repo_root/scripts/test-ci-integration.sh"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/npm" <<'EOF'
#!/bin/sh
printf 'npm %s (cwd=%s)\n' "$*" "$(pwd -P)" >>"$FAKE_NPM_LOG"
[ -z "${TEST_WORKER_INDEX:-}" ] || { echo 'fake npm: caller-controlled worker marker reached install' >&2; exit 1; }
[ -z "${TEST_PARALLEL_INDEX:-}" ] || { echo 'fake npm: caller-controlled parallel marker reached install' >&2; exit 1; }
[ "${1:-}" = ci ] || { echo 'fake npm: only npm ci is permitted' >&2; exit 1; }
[ "${2:-}" = --ignore-scripts ] || exit 1
[ "${3:-}" = --no-audit ] || exit 1
[ "$(pwd -P)" = "$FAKE_E2E_DIR" ] || { echo 'fake npm: install ran outside e2e directory' >&2; exit 1; }
[ -f package.json ] || { echo 'fake npm: package.json was not provided' >&2; exit 1; }
[ -f package-lock.json ] || { echo 'fake npm: package-lock.json was not provided' >&2; exit 1; }
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
case "${2:-}" in
  install)
    [ "${3:-}" = chromium ] || exit 1
    ;;
  test)
    [ "${3:-}" = --config ] || {
      echo 'fake node: Playwright test must receive generated config' >&2
      exit 1
    }
    config=${4:-}
    case "$config" in
      "$FAKE_E2E_DIR"/.playwright-lifecycle.*)
        [ -f "$config" ] || { echo 'fake node: generated config is missing' >&2; exit 1; }
        grep -Fq "testDir: \"$FAKE_E2E_DIR\"" "$config" || exit 1
        grep -Fq 'timeout: 30_000' "$config" || exit 1
        grep -Fq 'baseURL: process.env.APP_URL' "$config" || exit 1
        grep -Fq 'reporter: [["list"]]' "$config" || exit 1
        ;;
      *) echo 'fake node: unexpected generated config path' >&2; exit 1 ;;
    esac
    case "${FAKE_EXPECTED_SPEC:-all}" in
      all) [ -z "${5:-}" ] || { echo 'fake node: all mode received a test filter' >&2; exit 1; } ;;
      app) [ "${5:-}" = journey.spec.js ] || { echo 'fake node: app filter is missing' >&2; exit 1; } ;;
      dashboard) [ "${5:-}" = dashboard.spec.js ] || { echo 'fake node: dashboard filter is missing' >&2; exit 1; } ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/npm" "$tmp/bin/node"

before=$(shasum -a 256 "$repo_root/e2e/package-lock.json" | awk '{print $1}')
proof="$tmp/proof"
printf '%s\n' '{"version":3,"kind":"agentotel.e2e-ready.v3","mode":"all","dashboard_status":"ready","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$proof"

# Direct helper execution must fail before it can invoke npm, even with a
# caller-controlled legacy marker and a valid-looking readiness document.
if (
  PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" \
    AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE=all \
    AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
    COMPOSE_PROJECT_NAME=agentotel-contract \
    "$repo_root/scripts/run-browser-e2e.sh" all "$proof"
) >"$tmp/direct-helper.out" 2>&1; then
  echo 'direct browser helper accepted a forged lifecycle capability' >&2
  exit 1
fi
grep -Fq 'must be sourced, not executed directly' "$tmp/direct-helper.out"
[ ! -e "$tmp/npm.log" ] || { echo 'direct helper path invoked dependencies' >&2; exit 1; }

# argv[0] is mutable and must not turn direct execution into an approved caller.
if (
  bash -c 'exec -a "$1" bash "$2" all "$3"' bash \
    "$repo_root/scripts/run-e2e.sh" "$repo_root/scripts/run-browser-e2e.sh" "$proof"
) >"$tmp/argv-spoof.out" 2>&1; then
  echo 'argv-spoofed direct helper execution was accepted' >&2
  exit 1
fi
grep -Fq 'must be sourced, not executed directly' "$tmp/argv-spoof.out"

# A wrapper that sources the helper must still fail when argv[0] impersonates a
# lifecycle script; only the actual BASH_SOURCE caller is trusted.
cat >"$tmp/argv-spoof-runner.sh" <<EOF
#!/usr/bin/env bash
set -eu
. "$repo_root/scripts/run-browser-e2e.sh"
run_browser_e2e all "$proof"
EOF
chmod +x "$tmp/argv-spoof-runner.sh"
if (
  bash -c 'exec -a "$1" bash "$2"' bash \
    "$repo_root/scripts/run-e2e.sh" "$tmp/argv-spoof-runner.sh"
) >"$tmp/argv-source-spoof.out" 2>&1; then
  echo 'argv-spoofed source caller was accepted' >&2
  exit 1
fi
grep -Fq 'unapproved source' "$tmp/argv-source-spoof.out"

# Caller-controlled Playwright worker/readiness variables cannot load the
# repository's rejecting default config.
if (
  cd "$repo_root/e2e"
  AGENTOTEL_E2E_MODE=app TEST_WORKER_INDEX=1 \
    AGENTOTEL_E2E_READY_VERIFIED="$(printf '%064d' 0)" \
    node -e 'require("./playwright.config.js"); console.log("config-loaded")'
) >"$tmp/config-spoof.out" 2>&1; then
  echo 'caller-controlled worker markers bypassed default Playwright config rejection' >&2
  exit 1
fi
grep -Fq 'Direct npm E2E invocation is unsupported' "$tmp/config-spoof.out"

# Sourcing the library from an unrelated script is not a supported lifecycle
# caller and must fail before npm.
cat >"$tmp/unapproved-runner.sh" <<EOF
#!/usr/bin/env bash
set -eu
dirname() { printf '%s\\n' "$repo_root/scripts"; }
basename() { printf '%s\\n' run-e2e.sh; }
python3() { echo 'hostile python3 was invoked' >&2; exit 1; }
. "$repo_root/scripts/run-browser-e2e.sh"
run_browser_e2e all "$proof"
EOF
chmod +x "$tmp/unapproved-runner.sh"
if (
  PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" \
    AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
    COMPOSE_PROJECT_NAME=agentotel-contract \
    "$tmp/unapproved-runner.sh"
) >"$tmp/unapproved.out" 2>&1; then
  echo 'unapproved source caller was accepted' >&2
  exit 1
fi
grep -Fq 'unapproved source' "$tmp/unapproved.out"
if grep -Fq 'hostile python3 was invoked' "$tmp/unapproved.out"; then
  echo 'unapproved source caller invoked hostile python3 function' >&2
  exit 1
fi
[ ! -e "$tmp/npm.log" ] || { echo 'unapproved source caller invoked dependencies' >&2; exit 1; }

# Positive coverage uses the actual reusable helper from this contract test;
# it does not create a fake lifecycle parent or spoof argv[0].
: >"$tmp/npm.log"
export PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" \
  FAKE_PLAYWRIGHT_CLI="$repo_root/e2e/node_modules/playwright/cli.js" \
  FAKE_E2E_DIR="$repo_root/e2e" FAKE_EXPECTED_SPEC=all \
  TEST_WORKER_INDEX=1 TEST_PARALLEL_INDEX=1 \
  AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
  COMPOSE_PROJECT_NAME=agentotel-contract \
  APP_URL=http://127.0.0.1:3000 DASHBOARD_URL=http://127.0.0.1:3001 \
  DASHBOARD_E2E_AUTH_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  DASHBOARD_BOOTSTRAP_URL="http://127.0.0.1:3001/#token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
. "$repo_root/scripts/run-browser-e2e.sh"
run_browser_e2e all "$proof"

app_proof="$tmp/app-proof"
printf '%s\n' '{"version":3,"kind":"agentotel.e2e-ready.v3","mode":"app","dashboard_status":"not_required","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$app_proof"
FAKE_EXPECTED_SPEC=app
run_browser_e2e app "$app_proof"

dashboard_proof="$tmp/dashboard-proof"
printf '%s\n' '{"version":3,"kind":"agentotel.e2e-ready.v3","mode":"dashboard","dashboard_status":"ready","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$dashboard_proof"
FAKE_EXPECTED_SPEC=dashboard
run_browser_e2e dashboard "$dashboard_proof"

after=$(shasum -a 256 "$repo_root/e2e/package-lock.json" | awk '{print $1}')
test "$before" = "$after" || { echo 'package-lock changed during fake E2E run' >&2; exit 1; }
grep -Fq 'npm ci --ignore-scripts --no-audit' "$tmp/npm.log"
grep -Fq "npm ci --ignore-scripts --no-audit (cwd=$repo_root/e2e)" "$tmp/npm.log"
grep -Fq "node $repo_root/e2e/node_modules/playwright/cli.js install chromium" "$tmp/npm.log"
grep -Fq "node $repo_root/e2e/node_modules/playwright/cli.js test --config $repo_root/e2e/.playwright-lifecycle." "$tmp/npm.log"
grep -F "node $repo_root/e2e/node_modules/playwright/cli.js test --config $repo_root/e2e/.playwright-lifecycle." "$tmp/npm.log" | grep -Fq 'journey.spec.js'
grep -F "node $repo_root/e2e/node_modules/playwright/cli.js test --config $repo_root/e2e/.playwright-lifecycle." "$tmp/npm.log" | grep -Fq 'dashboard.spec.js'
if find "$repo_root/e2e" -maxdepth 1 -name '.playwright-lifecycle.*' -print -quit | grep -q .; then
  echo 'generated Playwright config was not cleaned up' >&2
  exit 1
fi
if grep -Fq 'npm install' "$tmp/npm.log"; then exit 1; fi
if grep -Fq 'npm run' "$tmp/npm.log"; then exit 1; fi

# Production authorization must not regress to mutable process metadata.
if grep -Eq 'launcher_pid|launcher_kind|AGENTOTEL_E2E_READY_FD|processAncestry|commandContainsPath|execFileSync' \
  "$repo_root/scripts/run-browser-e2e.sh" "$repo_root/e2e/playwright.config.js" "$repo_root/scripts/run-e2e.sh" "$repo_root/scripts/test-ci-integration.sh"; then
  echo 'production E2E lifecycle still contains mutable process attestation' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])ps[[:space:]]+-' \
  "$repo_root/scripts/run-browser-e2e.sh" "$repo_root/e2e/playwright.config.js" "$repo_root/scripts/run-e2e.sh" "$repo_root/scripts/test-ci-integration.sh"; then
  echo 'production E2E lifecycle still invokes process inspection' >&2
  exit 1
fi

if grep -R -Fq 'exec -a' "$repo_root/scripts/run-browser-e2e.sh" "$repo_root/e2e/playwright.config.js" "$repo_root/scripts/run-e2e.sh" "$repo_root/scripts/test-ci-integration.sh"; then
  echo 'production E2E lifecycle contains argv spoofing' >&2
  exit 1
fi

echo 'E2E command contract: PASS (source-bound lifecycle; no browser launched; lock preservation verified)'
