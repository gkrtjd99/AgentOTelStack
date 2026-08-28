#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

payload='{"schema_version":"v1","data":{"metrics":{"value":1},"logs":{"value":2}},"partial":false,"truncated":false,"content_trust":"untrusted_telemetry","backends":[]}'
token='overview-query-secret'

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CURL_LOG"
case "$*" in
  */v1/context*) printf '%s\n' "$PAYLOAD" ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env python3
import json
import sys

value = json.load(sys.stdin)
if sys.argv[1:] == ["-c"]:
    print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
else:
    print(json.dumps(value, indent=2, ensure_ascii=False))
EOF
chmod +x "$tmp/bin/jq"

run_obs() {
  env PATH="$tmp/bin:$PATH" \
    GATEWAY_URL=http://fake-gateway \
    GATEWAY_QUERY_TOKEN="$token" \
    CURL_LOG="$tmp/curl.log" \
    PAYLOAD="$payload" \
    "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_no_token() {
  if grep -Fq "$token" "$tmp/out" "$tmp/err"; then
    fail 'query token appeared in overview output'
  fi
}

run_ok() {
  local label="$*"
  if ! run_obs "$@" >"$tmp/out" 2>"$tmp/err"; then
    printf 'unexpected failure: %s\n' "$label" >&2
    exit 1
  fi
  assert_no_token
}

run_fail() {
  local label="$*"
  if run_obs "$@" >"$tmp/out" 2>"$tmp/err"; then
    printf 'unexpected success: %s\n' "$label" >&2
    exit 1
  fi
  assert_no_token
}

assert_request() {
  local service="$1" lookback="$2"
  grep -Fq -- "service=${service}" "$tmp/curl.log" || fail "service was not forwarded: ${service}"
  grep -Fq -- "lookback=${lookback}" "$tmp/curl.log" || fail "lookback was not forwarded: ${lookback}"
}

# Raw JSON bypasses jq, while the default uses the existing pretty-print helper.
run_ok "$root/obs/overview.sh" --global --json --since 6h checkout-service
[[ "$(<"$tmp/out")" == "$payload" ]] || fail '--json did not return the raw Gateway envelope'
assert_request checkout-service 6h

run_ok "$root/obs/overview.sh" --global checkout-service 15m
[[ "$(wc -l <"$tmp/out" | tr -d ' ')" -gt 1 ]] || fail 'default overview output is not pretty-printed'
assert_request checkout-service 15m

# Compact mode is a one-line JSON Gateway envelope, not a no-op alias.
run_ok "$root/obs/overview.sh" --global --compact checkout-service 5m
[[ "$(wc -l <"$tmp/out" | tr -d ' ')" -eq 1 ]] || fail 'compact overview output is not one line'
[[ "$(<"$tmp/out")" == "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), separators=(",", ":"), ensure_ascii=False))' <"$tmp/out")" ]] || fail 'compact overview output is not a JSON envelope'
assert_request checkout-service 5m

# app.sh summary must use the option form when delegating to overview.sh.
: >"$tmp/curl.log"
run_ok "$root/obs/app.sh" --global summary delegated-service 1h
assert_request delegated-service 1h

# Every Gateway-supported lookback is accepted.
for lookback in 5m 15m 1h 6h 24h; do
  run_ok "$root/obs/overview.sh" --global --json --lookback "$lookback" accepted-service
  assert_request accepted-service "$lookback"
done

# Invalid or ambiguous command lines fail before the Gateway is queried.
: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global --lookback
[[ ! -s "$tmp/curl.log" ]] || fail 'missing --lookback value queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global --since --json accepted-service
[[ ! -s "$tmp/curl.log" ]] || fail 'missing --since value queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global --unknown accepted-service
[[ ! -s "$tmp/curl.log" ]] || fail 'unknown option queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global accepted-service 15m extra
[[ ! -s "$tmp/curl.log" ]] || fail 'too many positional arguments queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global accepted-service 30m
[[ ! -s "$tmp/curl.log" ]] || fail 'invalid lookback queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global --lookback 1h --since 5m accepted-service
[[ ! -s "$tmp/curl.log" ]] || fail 'duplicate lookback options queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global accepted-service 15m --lookback 1h
[[ ! -s "$tmp/curl.log" ]] || fail 'duplicate positional/option lookback queried the Gateway'

: >"$tmp/curl.log"
run_fail "$root/obs/overview.sh" --global --json --compact accepted-service
[[ ! -s "$tmp/curl.log" ]] || fail 'conflicting output modes queried the Gateway'

echo 'PASS overview CLI parsing, output modes, delegation, lookback validation, and token redaction'
