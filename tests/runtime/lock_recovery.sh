#!/bin/sh
# Portable owner-aware lock recovery and release contracts.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/config" "$t/data" "$t/state" "$t/runtime" "$t/home"

# A dead owner is reclaimable, while a live owner is not.
lock="$t/state/agentotel/direct.lock"
mkdir -p "$lock"
printf '999999||dead-owner\n' >"$lock/owner"
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '. "$1/libexec/agentotel/common.sh"; lock_acquire "$2" direct 10; token=$AGENTOTEL_LOCK_TOKEN; lock_release "$2" "$token"' sh "$root" "$lock"
[ ! -e "$lock" ]

# A holder killed after publishing its owner record is reclaimable too (the
# crash path differs from a pre-created dead PID and must not wedge state).
killed_lock="$t/state/agentotel/killed.lock"
(sleep 30) & killed_pid=$!
killed_start=$(ps -o lstart= -p "$killed_pid" 2>/dev/null | sed 's/^ *//' || true)
mkdir -p "$killed_lock"
printf '%s|%s|killed-owner\n' "$killed_pid" "$killed_start" >"$killed_lock/owner"
kill -KILL "$killed_pid" 2>/dev/null || true
wait "$killed_pid" 2>/dev/null || true
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '. "$1/libexec/agentotel/common.sh"; lock_acquire "$2" killed 10; token=$AGENTOTEL_LOCK_TOKEN; lock_release "$2" "$token"' sh "$root" "$killed_lock"
[ ! -e "$killed_lock" ]

# A reused PID with a different process-start marker is stale, even though the
# numeric PID is currently live; recovery must not wedge on PID reuse.
reused_lock="$t/state/agentotel/reused.lock"
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '
    . "$1/libexec/agentotel/common.sh"
    mkdir -p "$2"
    printf "%s|not-the-current-process-start|reused-owner\\n" "$$" >"$2/owner"
    lock_acquire "$2" reused 10
    token=$AGENTOTEL_LOCK_TOKEN
    lock_release "$2" "$token"
  ' sh "$root" "$reused_lock"
[ ! -e "$reused_lock" ]

live_lock="$t/state/agentotel/live.lock"
mkdir -p "$live_lock"
(sleep 30) & live_pid=$!
live_start=$(ps -o lstart= -p "$live_pid" 2>/dev/null | sed 's/^ *//' || true)
printf '%s|%s|live-owner\n' "$live_pid" "$live_start" >"$live_lock/owner"
set +e
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '. "$1/libexec/agentotel/common.sh"; lock_acquire "$2" live 3' sh "$root" "$live_lock" >"$t/live.out" 2>&1
live_rc=$?
set -e
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
[ "$live_rc" -eq 75 ]
grep -q 'live busy' "$t/live.out"

# Owner-checked release cannot remove another owner's lock.
owner_lock="$t/state/agentotel/owner.lock"
mkdir -p "$owner_lock"
printf '%s|%s|other-owner\n' "$$" "$(ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//' || true)" >"$owner_lock/owner"
set +e
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '. "$1/libexec/agentotel/common.sh"; lock_release "$2" wrong-token' sh "$root" "$owner_lock"
owner_rc=$?
set -e
[ "$owner_rc" -ne 0 ]
[ -d "$owner_lock" ]
rm -rf "$owner_lock"

# Exercise stale recovery at the persisted stack, project, and credential paths.
stale_path() {
  mkdir -p "$1"
  printf '999999||stale-owner\n' >"$1/owner"
}
stale_path "$t/state/agentotel/stack.uuid.lock"
printf '%s\n' '11111111-1111-4111-1111-111111111111' >"$t/state/agentotel/stack.uuid"
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  "$root/libexec/agentotel/dispatch.sh" stack-id >/dev/null
[ ! -e "$t/state/agentotel/stack.uuid.lock" ]

mkdir -p "$t/repo"
git -C "$t/repo" init -q
git -C "$t/repo" config user.email test@example.invalid
git -C "$t/repo" config user.name test
stale_path "$t/repo/.agentotel.lock"
(
  cd "$t/repo"
  XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
    "$root/libexec/agentotel/project.sh" ensure >/dev/null
)
[ ! -e "$t/repo/.agentotel.lock" ]

stale_path "$t/state/agentotel/credentials.lock"
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  "$root/libexec/agentotel/credentials.sh" ensure >/dev/null
[ ! -e "$t/state/agentotel/credentials.lock" ]

# Symlinked lock paths and parents are fail-closed.
ln -s "$t/elsewhere" "$t/state/agentotel/symlink.lock"
set +e
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/runtime" \
  sh -c '. "$1/libexec/agentotel/common.sh"; lock_acquire "$2" symlink 2' sh "$root" "$t/state/agentotel/symlink.lock" >"$t/symlink.out" 2>&1
symlink_rc=$?
set -e
[ "$symlink_rc" -ne 0 ]
grep -q 'symlink rejected: symlink lock' "$t/symlink.out"

printf '%s\n' 'lock recovery checks passed (dead owners reclaimed; live owners and unsafe release rejected)'
