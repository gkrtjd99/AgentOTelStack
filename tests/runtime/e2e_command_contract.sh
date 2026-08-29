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
[ "${1:-}" = ci ] || { echo 'fake npm: only npm ci is permitted' >&2; exit 1; }
[ "${2:-}" = --ignore-scripts ] || exit 1
[ "${3:-}" = --no-audit ] || exit 1
exit 0
EOF
cat >"$tmp/bin/node" <<'EOF'
#!/bin/sh
printf 'node %s\n' "$*" >>"$FAKE_NPM_LOG"
[ "${1:-}" = "$FAKE_PLAYWRIGHT_CLI" ] || {
  echo 'fake node: unexpected Playwright CLI path' >&2
  exit 1
}
case "${2:-}" in install|test) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$tmp/bin/npm" "$tmp/bin/node"

# The historical caller-controlled marker must not reach dependency install or
# Playwright. This negative check is intentionally performed before the valid
# capability run, so a fake npm cannot make the bypass look successful.
if PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" \
  AGENTOTEL_E2E_STACK_READY=1 \
  APP_URL=http://127.0.0.1:3000 DASHBOARD_URL=http://127.0.0.1:3001 \
  DASHBOARD_E2E_AUTH_TOKEN="$(printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)" \
  DASHBOARD_BOOTSTRAP_URL="http://127.0.0.1:3001/#token=$(printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)" \
  "$root/scripts/run-browser-e2e.sh" all >"$tmp/missing-capability.out" 2>&1; then
  echo 'caller-controlled E2E readiness marker bypassed the lifecycle handoff' >&2
  exit 1
fi
grep -Fq 'missing inherited lifecycle readiness capability' "$tmp/missing-capability.out"
[ ! -e "$tmp/npm.log" ] || { echo 'missing-capability path installed dependencies' >&2; exit 1; }

before=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
proof="$tmp/proof"
printf '%s\n' '{"version":1,"kind":"agentotel.e2e-ready.v1","mode":"all","dashboard_status":"ready","project_id":"00000000-0000-4000-8000-000000000002","compose_project":"agentotel-contract","issued_at":'"$(date +%s)"',"nonce":"0123456789abcdef0123456789abcdef"}' >"$proof"
(
  exec 9<"$proof"
  rm -f "$proof"
  export AGENTOTEL_E2E_READY_FD=9 AGENTOTEL_E2E_MODE=all
  export AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002
  export COMPOSE_PROJECT_NAME=agentotel-contract
  export FAKE_NPM_LOG="$tmp/npm.log" FAKE_PLAYWRIGHT_CLI="$root/e2e/node_modules/playwright/cli.js" PATH="$tmp/bin:$PATH"
  export APP_URL=http://127.0.0.1:3000 DASHBOARD_URL=http://127.0.0.1:3001
  dashboard_auth_token=$(printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
  export DASHBOARD_E2E_AUTH_TOKEN="$dashboard_auth_token"
  export DASHBOARD_BOOTSTRAP_URL="http://127.0.0.1:3001/#token=$DASHBOARD_E2E_AUTH_TOKEN"
  "$root/scripts/run-browser-e2e.sh" all
)

after=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
test "$before" = "$after" || { echo 'package-lock changed during fake E2E run' >&2; exit 1; }
grep -Fq 'npm ci --ignore-scripts --no-audit' "$tmp/npm.log"
grep -Fq "node $root/e2e/node_modules/playwright/cli.js install chromium" "$tmp/npm.log"
grep -Fq "node $root/e2e/node_modules/playwright/cli.js test" "$tmp/npm.log"
if grep -Fq 'npm install' "$tmp/npm.log"; then exit 1; fi
if grep -Fq 'npm run' "$tmp/npm.log"; then exit 1; fi

echo 'E2E command contract: PASS (inherited readiness capability; no browser launched; lock preservation verified)'
