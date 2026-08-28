#!/bin/sh
# Exercise the standalone installer's per-version owner-aware lock.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-install-concurrency.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
source_clone="$t/source"
cp -R "$root" "$source_clone"
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_CONFIG_HOME="$t/config"
mkdir -p "$HOME"

# The first post-lock cp pauses while the second installer contends. Both use
# the same XDG store and exact version; only the lock winner may publish it.
mkdir -p "$t/bin"
real_cp=$(command -v cp)
cat >"$t/bin/cp" <<EOF
#!/bin/sh
if [ ! -e "$t/first-cp" ]; then
  : >"$t/first-cp"
  sleep 0.35
fi
exec "$real_cp" "\$@"
EOF
chmod +x "$t/bin/cp"
set +e
(PATH="$t/bin:$PATH" "$source_clone/scripts/install.sh" --without-mcp 7.0.0 >"$t/one.out" 2>&1) &
pid_one=$!
sleep 0.05
(PATH="$t/bin:$PATH" "$source_clone/scripts/install.sh" --without-mcp 7.0.0 >"$t/two.out" 2>&1) &
pid_two=$!
wait "$pid_one"; rc_one=$?
wait "$pid_two"; rc_two=$?
set -e
successes=0
[ "$rc_one" -eq 0 ] && successes=$((successes + 1))
[ "$rc_two" -eq 0 ] && successes=$((successes + 1))
[ "$successes" -eq 1 ] || { echo "concurrent install expected one winner: rc_one=$rc_one rc_two=$rc_two" >&2; exit 1; }
test -d "$XDG_DATA_HOME/agentotel/7.0.0"
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 7.0.0
test ! -e "$XDG_DATA_HOME/agentotel/.install-7.0.0.lock"
if find "$XDG_DATA_HOME/agentotel" -maxdepth 1 \( -name '.staging-7.0.0-*' -o -name '.install-7.0.0.lock' \) -print -quit | grep -q .; then
  echo 'concurrent install left stage or lock residue' >&2
  exit 1
fi
grep -F 'another installer won' "$t/one.out" "$t/two.out" >/dev/null

# A dead owner is reclaimable, but a normal publication failure releases both
# lock and stage and does not alter current/previous pointers.
mkdir -p "$XDG_DATA_HOME/agentotel/.install-8.0.0.lock"
printf '999999|dead-process-start|dead-token\n' >"$XDG_DATA_HOME/agentotel/.install-8.0.0.lock/owner"
PATH="$PATH" "$source_clone/scripts/install.sh" --without-mcp 8.0.0 >"$t/recovered.out"
test -d "$XDG_DATA_HOME/agentotel/8.0.0"
test ! -e "$XDG_DATA_HOME/agentotel/.install-8.0.0.lock"
old_current=$(readlink "$XDG_DATA_HOME/agentotel/current")
old_previous=$(readlink "$XDG_DATA_HOME/agentotel/previous")
mkdir -p "$t/fail-bin"
real_mv=$(command -v mv)
cat >"$t/fail-bin/mv" <<EOF
#!/bin/sh
last=''
for arg do last=\$arg; done
if [ "\$last" = "$XDG_DATA_HOME/agentotel/9.0.0" ]; then
  printf 'forced publication failure\n' >&2
  exit 73
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$t/fail-bin/mv"
set +e
PATH="$t/fail-bin:$PATH" "$source_clone/scripts/install.sh" --without-mcp 9.0.0 >"$t/publication-failure.out" 2>&1
failure_rc=$?
set -e
[ "$failure_rc" -ne 0 ] || { echo 'forced publication failure unexpectedly passed' >&2; exit 1; }
test ! -e "$XDG_DATA_HOME/agentotel/9.0.0"
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = "$old_current"
test "$(readlink "$XDG_DATA_HOME/agentotel/previous")" = "$old_previous"
test ! -e "$XDG_DATA_HOME/agentotel/.install-9.0.0.lock"
if find "$XDG_DATA_HOME/agentotel" -maxdepth 1 \( -name '.staging-9.0.0-*' -o -name '.install-9.0.0.lock' \) -print -quit | grep -q .; then
  echo 'forced publication failure left stage or lock residue' >&2
  exit 1
fi
echo 'installer concurrency fixtures: PASS (one winner, dead-owner recovery, publication rollback cleanup)'
