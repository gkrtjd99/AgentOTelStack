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
# Existing and dangling stack identity symlinks are both rejected before read.
stack_file="$XDG_STATE_HOME/agentotel/stack.uuid"
printf '%s\n' 99999999-9999-4999-8999-999999999999 >"$tmp/stack-target"
ln -s "$tmp/stack-target" "$stack_file"
if "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/symlink.out" 2>&1; then
  echo 'existing stack.uuid symlink was accepted' >&2; exit 1
fi
grep -q 'symlink rejected' "$tmp/symlink.out"
rm -f "$stack_file"
ln -s "$tmp/dangling-target" "$stack_file"
if "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/dangling.out" 2>&1; then
  echo 'dangling stack.uuid symlink was accepted' >&2; exit 1
fi
grep -q 'symlink rejected' "$tmp/dangling.out"
rm -f "$stack_file"
printf '%s\n' abcdef12-abcd-4abc-8abc-abcdef123456 | tr 'a-f' 'A-F' >"$stack_file"
if "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/uppercase.out" 2>&1; then
  echo 'uppercase persisted stack UUID was accepted' >&2; exit 1
fi
grep -q 'invalid stack UUID' "$tmp/uppercase.out"
rm -f "$stack_file"
# Delay UUID generation to force two first readers through the portable lock.
mkdir -p "$tmp/fakebin"
real_od=$(command -v od)
cat >"$tmp/fakebin/od" <<EOF
#!/bin/sh
sleep .1
exec "$real_od" "\$@"
EOF
chmod 755 "$tmp/fakebin/od"
PATH="$tmp/fakebin:$PATH" "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/identity-one" & identity_one_pid=$!
PATH="$tmp/fakebin:$PATH" "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/identity-two" & identity_two_pid=$!
wait "$identity_one_pid" "$identity_two_pid"
[ "$(cat "$tmp/identity-one")" = "$(cat "$tmp/identity-two")" ]
[ "$(cat "$stack_file")" = "$(cat "$tmp/identity-one")" ]
printf '%s\n' "$(cat "$stack_file")" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
rm -f "$stack_file"
explicit_stack=11111111-1111-4111-8111-111111111111
resolved_stack=$(AGENTOTEL_STACK_UUID="$explicit_stack" "$ROOT/libexec/agentotel/dispatch.sh" stack-id)
[ "$resolved_stack" = "$explicit_stack" ]
[ "$(cat "$XDG_STATE_HOME/agentotel/stack.uuid")" = "$explicit_stack" ]
if AGENTOTEL_STACK_UUID=22222222-2222-4222-8222-222222222222 "$ROOT/libexec/agentotel/dispatch.sh" stack-id >"$tmp/stack-mismatch.out" 2>&1; then
  echo 'explicit stack UUID mismatch unexpectedly replaced persisted identity' >&2
  exit 1
fi
grep -q 'does not match persisted stack UUID' "$tmp/stack-mismatch.out"
[ "$(AGENTOTEL_STACK_UUID='' "$ROOT/libexec/agentotel/dispatch.sh" stack-id)" = "$explicit_stack" ]
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
if env | grep -Eq '^GF_[^=]*='; then exit 1; fi
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
