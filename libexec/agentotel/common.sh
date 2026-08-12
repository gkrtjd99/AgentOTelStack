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
mkdirs(){
  for d in "$CFG" "$DATA" "$STATE" "$RUNTIME"; do
    if [ -L "$d" ]; then
      die "symlink rejected: $d"
    fi
  done
  mkdir -p "$CFG" "$DATA" "$STATE" "$RUNTIME"
  chmod 700 "$CFG" "$DATA" "$STATE" "$RUNTIME"
}
reject_symlink(){ [ ! -L "$1" ] || die "symlink rejected: $1"; }
safe_parent(){ reject_symlink "$1"; p=$(dirname "$1"); [ ! -L "$p" ] || die "symlink parent rejected: $p"; }
json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
rand_uuid(){ od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | awk '{printf "%s-%s-%s-%s-%s\n",substr($0,1,8),substr($0,9,4),substr($0,13,4),substr($0,17,4),substr($0,21,12)}'; }
valid_uuid(){ printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
atomic(){ tmp="$1.tmp.$$"; (umask 077; cat > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }

# Load the local credential store into child processes without ever echoing a
# secret.  Compose requires literal values for its required-variable checks,
# so token-file variables alone are not sufficient here.  Values explicitly
# supplied by an operator win; the store only fills missing values.
load_credentials(){
  f="$CFG/credentials"
  [ -e "$f" ] || return 0
  [ ! -L "$f" ] || die 'credential symlink rejected'
  [ -f "$f" ] || die 'credential store is not a regular file'
  chmod 600 "$f"
  for key in ingest_token query_token grafana_admin_password; do
    value=$(sed -n "s/.*\"$key\":\"\([0-9a-f][0-9a-f]*\)\".*/\1/p" "$f")
    [ -n "$value" ] || continue
    case "$value" in *[!0-9a-f]*) die "credential store has invalid $key";; esac
    case "$key" in
      ingest_token) [ -n "${GATEWAY_INGEST_TOKEN:-}" ] || export GATEWAY_INGEST_TOKEN="$value" ;;
      query_token) [ -n "${GATEWAY_QUERY_TOKEN:-}" ] || export GATEWAY_QUERY_TOKEN="$value" ;;
      grafana_admin_password) [ -n "${GF_SECURITY_ADMIN_PASSWORD:-}" ] || export GF_SECURITY_ADMIN_PASSWORD="$value" ;;
    esac
  done
}

load_credentials
