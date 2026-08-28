#!/usr/bin/env bash
# Install and execute Playwright without mutating the E2E lockfile.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="$ROOT/e2e"
mode="${1:-all}"

case "$mode" in
  all|app|dashboard) ;;
  *) echo "run-browser-e2e: usage: $0 {all|app|dashboard}" >&2; exit 2 ;;
esac
command -v npm >/dev/null 2>&1 || { echo 'run-browser-e2e: npm is unavailable' >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo 'run-browser-e2e: npx is unavailable' >&2; exit 1; }
[[ -f "$E2E_DIR/package-lock.json" ]] || { echo 'run-browser-e2e: package-lock.json is missing' >&2; exit 1; }

lock_before="$(shasum -a 256 "$E2E_DIR/package-lock.json" | awk '{print $1}')"
(
  cd "$E2E_DIR"
  npm ci --ignore-scripts --no-audit
)
lock_after="$(shasum -a 256 "$E2E_DIR/package-lock.json" | awk '{print $1}')"
[[ "$lock_before" == "$lock_after" ]] || {
  echo 'run-browser-e2e: npm ci mutated e2e/package-lock.json' >&2
  exit 1
}

browser_args=(install chromium)
if [[ "${CI:-0}" == 1 || "${PLAYWRIGHT_INSTALL_WITH_DEPS:-0}" == 1 ]]; then
  browser_args=(install --with-deps chromium)
fi
(
  cd "$E2E_DIR"
  npx --no-install playwright "${browser_args[@]}"
)

case "$mode" in
  all) test_args=(test) ;;
  app) test_args=(test journey.spec.js) ;;
  dashboard) test_args=(test dashboard.spec.js) ;;
esac

export AGENTOTEL_E2E_STACK_READY=1
if [[ "$mode" == dashboard || "$mode" == all ]]; then
  export DASHBOARD_E2E_LIVE=1
  if [[ ! "${DASHBOARD_E2E_AUTH_TOKEN:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'run-browser-e2e: live Dashboard E2E requires a generated client token' >&2
    exit 1
  fi
  if ! DASHBOARD_URL="$("$ROOT/scripts/validate-dashboard-url.sh" "${DASHBOARD_URL:-}" "${DASHBOARD_HOST_PORT:-3001}" 2>&1)"; then
    echo "run-browser-e2e: $DASHBOARD_URL" >&2
    exit 1
  fi
  export DASHBOARD_URL
  expected_bootstrap_url="${DASHBOARD_URL}/#token=${DASHBOARD_E2E_AUTH_TOKEN}"
  [[ "${DASHBOARD_BOOTSTRAP_URL:-}" == "$expected_bootstrap_url" ]] || {
    echo 'run-browser-e2e: live Dashboard E2E requires a matching bootstrap URL' >&2
    exit 1
  }
fi
(
  cd "$E2E_DIR"
  npx --no-install playwright "${test_args[@]}"
)
