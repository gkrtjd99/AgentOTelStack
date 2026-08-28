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
cat >"$tmp/bin/npx" <<'EOF'
#!/bin/sh
printf 'npx %s\n' "$*" >>"$FAKE_NPM_LOG"
[ "${1:-}" = --no-install ] || { echo 'fake npx: --no-install is required' >&2; exit 1; }
[ "${2:-}" = playwright ] || exit 1
case "${3:-}" in install|test) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$tmp/bin/npm" "$tmp/bin/npx"
before=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
token_half=$(printf '%s' 01234567 89abcdef)
fake_dashboard_token=$(printf '%s' "$token_half" "$token_half" "$token_half" "$token_half")
FAKE_NPM_LOG="$tmp/npm.log" PATH="$tmp/bin:$PATH" \
  APP_URL=http://127.0.0.1:3000 DASHBOARD_URL=http://127.0.0.1:3001 \
  DASHBOARD_E2E_AUTH_TOKEN="$fake_dashboard_token" \
  DASHBOARD_BOOTSTRAP_URL="http://127.0.0.1:3001/#token=$fake_dashboard_token" \
  "$root/scripts/run-browser-e2e.sh" all

after=$(shasum -a 256 "$root/e2e/package-lock.json" | awk '{print $1}')
test "$before" = "$after" || { echo 'package-lock changed during fake E2E run' >&2; exit 1; }
grep -Fq 'npm ci --ignore-scripts --no-audit' "$tmp/npm.log"
grep -Fq 'npx --no-install playwright install chromium' "$tmp/npm.log"
grep -Fq 'npx --no-install playwright test' "$tmp/npm.log"
if grep -Fq 'npm install' "$tmp/npm.log"; then exit 1; fi
if grep -Fq 'npm run' "$tmp/npm.log"; then exit 1; fi

echo 'E2E command contract: PASS (no browser launched; npm ci lock preservation and npx --no-install verified)'
