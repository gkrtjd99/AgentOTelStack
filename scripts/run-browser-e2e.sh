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
command -v node >/dev/null 2>&1 || { echo 'run-browser-e2e: node is unavailable' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'run-browser-e2e: python3 is unavailable' >&2; exit 1; }
[[ -f "$E2E_DIR/package-lock.json" ]] || { echo 'run-browser-e2e: package-lock.json is missing' >&2; exit 1; }

# The lifecycle parent hands over an unlinked, inherited file descriptor only
# after Compose readiness and runtime evidence have completed. A caller-set
# environment marker is not accepted as proof. os.pread validates without
# advancing the descriptor, leaving the same proof available to Playwright.
ready_fd="${AGENTOTEL_E2E_READY_FD:-}"
[[ "$ready_fd" =~ ^[3-9][0-9]*$ ]] || {
  echo 'run-browser-e2e: missing inherited lifecycle readiness capability' >&2
  exit 1
}
python3 - "$ready_fd" "$mode" "${AGENTOTEL_PROJECT_ID:-}" "${COMPOSE_PROJECT_NAME:-}" <<'PY'
import json
import os
import re
import sys
import time

fd = int(sys.argv[1])
mode = sys.argv[2]
expected_project_id = sys.argv[3]
expected_compose_project = sys.argv[4]
try:
    raw = os.pread(fd, 65536, 0)
    proof = json.loads(raw.decode("utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"run-browser-e2e: invalid lifecycle readiness capability: {exc}")

expected_dashboard_status = "ready" if mode in ("all", "dashboard") else "not_required"
required = {
    "version": 1,
    "kind": "agentotel.e2e-ready.v1",
    "mode": mode,
    "dashboard_status": expected_dashboard_status,
}
for key, value in required.items():
    if proof.get(key) != value:
        raise SystemExit(f"run-browser-e2e: readiness capability has invalid {key}")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", proof.get("project_id", "")):
    raise SystemExit("run-browser-e2e: readiness capability has invalid project UUID")
if expected_project_id and proof["project_id"] != expected_project_id:
    raise SystemExit("run-browser-e2e: readiness capability project UUID does not match lifecycle")
if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", proof.get("compose_project", "")):
    raise SystemExit("run-browser-e2e: readiness capability has invalid Compose project")
if expected_compose_project and proof["compose_project"] != expected_compose_project:
    raise SystemExit("run-browser-e2e: readiness capability Compose project does not match lifecycle")
if not re.fullmatch(r"[0-9a-f]{32}", proof.get("nonce", "")):
    raise SystemExit("run-browser-e2e: readiness capability has invalid nonce")
issued_at = proof.get("issued_at")
if not isinstance(issued_at, int) or abs(time.time() - issued_at) > 600:
    raise SystemExit("run-browser-e2e: lifecycle readiness capability is stale")
PY
# Do not let caller-supplied worker markers alter the main/worker distinction.
unset TEST_WORKER_INDEX TEST_PARALLEL_INDEX AGENTOTEL_E2E_READY_VERIFIED

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
playwright_cli="$E2E_DIR/node_modules/playwright/cli.js"
[[ -r "$playwright_cli" ]] || {
  echo 'run-browser-e2e: npm ci did not install the Playwright CLI' >&2
  exit 1
}

browser_args=(install chromium)
if [[ "${CI:-0}" == 1 || "${PLAYWRIGHT_INSTALL_WITH_DEPS:-0}" == 1 ]]; then
  browser_args=(install --with-deps chromium)
fi
(
  cd "$E2E_DIR"
  node "$playwright_cli" "${browser_args[@]}"
)

case "$mode" in
  all) test_args=(test) ;;
  app) test_args=(test journey.spec.js) ;;
  dashboard) test_args=(test dashboard.spec.js) ;;
esac

export AGENTOTEL_E2E_MODE="$mode"
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
  node "$playwright_cli" "${test_args[@]}"
)
