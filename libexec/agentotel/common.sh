#!/bin/sh
set -eu
umask 077
RUNTIME_ROOT=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
VERSION=${VERSION:-unknown}
[ -f "$RUNTIME_ROOT/VERSION" ] && VERSION=$(cat "$RUNTIME_ROOT/VERSION")
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-${HOME:?}/.config}; XDG_DATA_HOME=${XDG_DATA_HOME:-${HOME:?}/.local/share}; XDG_STATE_HOME=${XDG_STATE_HOME:-${HOME:?}/.local/state}; XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/agentotel-$(id -u)}
CFG="$XDG_CONFIG_HOME/agentotel"; DATA="$XDG_DATA_HOME/agentotel"; STATE="$XDG_STATE_HOME/agentotel"; RUNTIME="$XDG_RUNTIME_DIR/agentotel"
ASSETS="$RUNTIME_ROOT/assets"
if [ -f "$ASSETS/docker-compose.yml" ]; then export COMPOSE_FILE="$ASSETS/docker-compose.yml"; export AGENTOTEL_ASSETS="$ASSETS"; fi
die(){ echo "agentotel: $1" >&2; exit "${2:-2}"; }
mkdirs(){ mkdir -p "$CFG" "$DATA" "$STATE" "$RUNTIME"; chmod 700 "$CFG" "$DATA" "$STATE" "$RUNTIME"; }
reject_symlink(){ [ ! -L "$1" ] || die "symlink rejected: $1"; }
safe_parent(){ reject_symlink "$1"; p=$(dirname "$1"); [ ! -L "$p" ] || die "symlink parent rejected: $p"; }
json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
rand_uuid(){ od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | awk '{printf "%s-%s-%s-%s-%s\n",substr($0,1,8),substr($0,9,4),substr($0,13,4),substr($0,17,4),substr($0,21,12)}'; }
valid_uuid(){ printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
atomic(){ tmp="$1.tmp.$$"; (umask 077; cat > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }
