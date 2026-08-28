#!/bin/sh
# Fake HTTP contract for API-level dashboard readiness.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=
auth=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -H) auth=$2; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -sS|-s|-S) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) echo "unexpected curl argument: $1" >&2; exit 24 ;;
  esac
done
[ "$auth" = "Authorization: Dashboard $FAKE_DASHBOARD_TOKEN" ] || exit 22
[ "$url" = "$FAKE_DASHBOARD_URL/api/services" ] || exit 23
case "$FAKE_READINESS_SCENARIO" in
  healthy)
    body='{"schema_version":"dashboard.v1","kind":"services","partial":false,"scope":{"project_bound":true},"backends":[{"name":"logs","status":"no_matching_data"},{"name":"metrics","status":"no_matching_data"}]}'
    status=200 ;;
  partial)
    body='{"schema_version":"dashboard.v1","kind":"services","partial":true,"scope":{"project_bound":true},"backends":[{"name":"logs","status":"backend_unavailable"},{"name":"metrics","status":"ok"}]}'
    status=200 ;;
  unsupported)
    body='{"schema_version":"dashboard.v1","kind":"services","partial":false,"scope":{"project_bound":true},"backends":[{"name":"logs","status":"unsupported"},{"name":"metrics","status":"ok"}]}'
    status=200 ;;
  slow)
    sleep 5
    body='{"schema_version":"dashboard.v1","kind":"services","partial":false,"scope":{"project_bound":true},"backends":[{"name":"logs","status":"ok"},{"name":"metrics","status":"ok"}]}'
    status=200 ;;
  *) body='{"error":"not ready"}'; status=503 ;;
esac
printf '%s' "$body" >"$out"
printf '%s' "$status"
EOF
chmod +x "$tmp/bin/curl"

token_half=$(printf '%s' 01234567 89abcdef)
client_token=$(printf '%s' "$token_half" "$token_half" "$token_half" "$token_half")
FAKE_READINESS_SCENARIO=healthy FAKE_DASHBOARD_TOKEN="$client_token" FAKE_DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_READY_TIMEOUT=3 PATH="$tmp/bin:$PATH" \
  DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_CLIENT_TOKEN="$client_token" "$root/scripts/dashboard-readiness.sh" >/dev/null
for scenario in partial unsupported unavailable; do
  if FAKE_READINESS_SCENARIO="$scenario" FAKE_DASHBOARD_TOKEN="$client_token" FAKE_DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_READY_TIMEOUT=1 PATH="$tmp/bin:$PATH" \
    DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_CLIENT_TOKEN="$client_token" "$root/scripts/dashboard-readiness.sh" >"$tmp/$scenario.out" 2>&1; then
    echo "$scenario dashboard readiness was accepted" >&2
    exit 1
  fi
done
slow_start=$(date +%s)
if FAKE_READINESS_SCENARIO=slow FAKE_DASHBOARD_TOKEN="$client_token" FAKE_DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_READY_TIMEOUT=1 PATH="$tmp/bin:$PATH" \
  DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_CLIENT_TOKEN="$client_token" "$root/scripts/dashboard-readiness.sh" >"$tmp/slow.out" 2>&1; then
  echo 'slow dashboard readiness unexpectedly succeeded' >&2
  exit 1
fi
slow_elapsed=$(( $(date +%s) - slow_start ))
[ "$slow_elapsed" -le 3 ] || { echo "slow curl exceeded wall-clock deadline: ${slow_elapsed}s" >&2; exit 1; }
for bad_url in http://host.docker.internal:3001 http://127.0.0.1:4000 'http://127.0.0.1:3001/#token=bad'; do
  if FAKE_DASHBOARD_TOKEN="$client_token" FAKE_DASHBOARD_URL=http://127.0.0.1:3001 DASHBOARD_READY_TIMEOUT=1 PATH="$tmp/bin:$PATH" \
    DASHBOARD_URL="$bad_url" DASHBOARD_CLIENT_TOKEN="$client_token" "$root/scripts/dashboard-readiness.sh" >"$tmp/bad-url.out" 2>&1; then
    echo "unsafe Dashboard URL was accepted: $bad_url" >&2
    exit 1
  fi
done

echo 'dashboard readiness contract: PASS (healthy no-data accepted; partial and operational failures rejected)'
