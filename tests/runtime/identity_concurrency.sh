#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state"
mkdir -p "$HOME" "$tmp/repo"; cd "$tmp/repo"
git init -q; git config user.email test@example.invalid; git config user.name test
printf base >file; git add file; git commit -qm base
"$ROOT/libexec/agentotel/dispatch.sh" init >/dev/null
one=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); cid=$(printf '%s' "$one" | sed -n 's/.*"checkout_id":"\([^"]*\)".*/\1/p')
test -n "$cid"; test ! -e .agentotel/checkout_id
printf unstaged >>file; two=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); test "$one" != "$two"
git add file; three=$("$ROOT/libexec/agentotel/dispatch.sh" source-state); test "$two" != "$three"
mkdir -p "$tmp/bin"; cat >"$tmp/bin/worker" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT HUP
sleep 30
EOF
chmod +x "$tmp/bin/worker"
"$ROOT/libexec/agentotel/dispatch.sh" run -- "$tmp/bin/worker" & p1=$!
"$ROOT/libexec/agentotel/dispatch.sh" run -- "$tmp/bin/worker" & p2=$!
i=0; while [ "$i" -lt 30 ] && [ -z "$("$ROOT/libexec/agentotel/dispatch.sh" runs)" ]; do i=$((i+1)); sleep .05; done
set +e; out=$("$ROOT/libexec/agentotel/dispatch.sh" run stop 2>&1); rc=$?; set -e
test "$rc" -ne 0; grep -q scope_ambiguous <<<"$out"
for f in "$XDG_STATE_HOME"/agentotel/runs/*.json; do [ -f "$f" ] || continue; pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f"); kill "$pid" 2>/dev/null || :; done
wait "$p1" "$p2" 2>/dev/null || :
echo 'identity/concurrency checks passed'
