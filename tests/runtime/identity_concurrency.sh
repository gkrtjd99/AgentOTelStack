#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state"
mkdir -p "$HOME" "$tmp/repo"; cd "$tmp/repo"
git init -q; git config user.email test@example.invalid; git config user.name test
printf base >file; git add file; git commit -qm base
"$ROOT/libexec/agentotel/dispatch.sh" init >/dev/null
"$ROOT/libexec/agentotel/dispatch.sh" credentials ensure >/dev/null
project_id=$(sed -n 's/.*project_id = "\([^"]*\)".*/\1/p' .agentotel/project.toml)
printf '%s\n' "$project_id" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
one=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); cid=$(printf '%s' "$one" | sed -n 's/.*"checkout_id":"\([^"]*\)".*/\1/p')
test -n "$cid"; test ! -e .agentotel/checkout_id
printf '%s\n' "$cid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
printf unstaged >>file; two=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); test "$one" != "$two"
git add file; three=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); test "$two" != "$three"
mkdir -p "$tmp/bin"; cat >"$tmp/bin/worker" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT HUP
sleep 30
EOF
chmod +x "$tmp/bin/worker"
cat >"$tmp/bin/env-check" <<'EOF'
#!/bin/sh
set -eu
[ "$OTEL_SERVICE_NAME" = test-service ]
[ -n "$OTEL_EXPORTER_OTLP_ENDPOINT" ]
[ "$OTEL_RESOURCE_ATTRIBUTES" = agentotel.project.id="$EXPECTED_PROJECT_ID" ]
[ "$OTEL_EXPORTER_OTLP_HEADERS" = Authorization=Bearer%20aaaaaaaa ]
[ -z "${GATEWAY_INGEST_TOKEN:-}" ]
[ -z "${GATEWAY_QUERY_TOKEN:-}" ]
[ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]
EOF
chmod +x "$tmp/bin/env-check"
EXPECTED_PROJECT_ID="$project_id" GATEWAY_INGEST_TOKEN=aaaaaaaa "$ROOT/libexec/agentotel/dispatch.sh" run --service test-service -- "$tmp/bin/env-check"
wait_for_runs() {
  expected=$1
  label=$2
  i=0
  while [ "$i" -lt 60 ]; do
    count=$(find "$XDG_STATE_HOME/agentotel/runs" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge "$expected" ] && return 0
    i=$((i+1)); sleep .05
  done
  echo "identity/concurrency: timed out waiting for $expected run records ($label); observed $count" >&2
  "$ROOT/libexec/agentotel/dispatch.sh" runs >&2 || :
  return 1
}
mkdir "$tmp/quoted\"scope"; quoted_repo="$tmp/quoted\"scope/repo"; mkdir -p "$quoted_repo"; git init -q "$quoted_repo"; (
  cd "$quoted_repo"; git config user.email test@example.invalid; git config user.name test
  "$ROOT/libexec/agentotel/dispatch.sh" init >/dev/null
  GATEWAY_INGEST_TOKEN=aaaaaaaa "$ROOT/libexec/agentotel/dispatch.sh" run --service quoted -- "$tmp/bin/worker" & quoted_pid=$!
  wait_for_runs 1 quoted-scope
  if command -v jq >/dev/null 2>&1; then "$ROOT/libexec/agentotel/dispatch.sh" runs | jq -e 'select(.scope | endswith("quoted\"scope/repo"))' >/dev/null; fi
  "$ROOT/libexec/agentotel/dispatch.sh" run stop
  wait "$quoted_pid" 2>/dev/null || :
)
"$ROOT/libexec/agentotel/dispatch.sh" run -- "$tmp/bin/worker" & p1=$!
"$ROOT/libexec/agentotel/dispatch.sh" run -- "$tmp/bin/worker" & p2=$!
wait_for_runs 2 concurrent-scope
set +e; out=$("$ROOT/libexec/agentotel/dispatch.sh" run stop 2>&1); rc=$?; set -e
if [ "$rc" -eq 0 ]; then
  echo "identity/concurrency: expected scope_ambiguous from concurrent stop, got rc=0" >&2
  echo "$out" >&2
  exit 1
fi
if ! grep -q scope_ambiguous <<<"$out"; then
  echo "identity/concurrency: concurrent stop failed with unexpected output:" >&2
  echo "$out" >&2
  exit 1
fi
for f in "$XDG_STATE_HOME"/agentotel/runs/*.json; do [ -f "$f" ] || continue; pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f"); kill "$pid" 2>/dev/null || :; done
wait "$p1" "$p2" 2>/dev/null || :
echo 'identity/concurrency checks passed'
