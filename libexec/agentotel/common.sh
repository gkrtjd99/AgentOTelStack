#!/bin/sh
set -eu
umask 077
RUNTIME_ROOT=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
VERSION=${VERSION:-unknown}
[ -f "$RUNTIME_ROOT/VERSION" ] && VERSION=$(cat "$RUNTIME_ROOT/VERSION")
# Compose uses this value to keep locally built images tied to the selected
# runtime. Installed current/previous runtimes resolve VERSION from their own
# immutable root; checkout development falls back to the repository VERSION.
# Keep the value within Docker's tag grammar even when a checkout has a
# hand-edited VERSION file. Installed versions are validated by install.sh;
# unsafe development values deliberately use the stable dev tag.
case "$VERSION" in
  [A-Za-z0-9_]*|[A-Za-z0-9_]*[A-Za-z0-9._-])
    case "$VERSION" in *[!A-Za-z0-9._-]*|'') VERSION=dev;; esac
    ;;
  *) VERSION=dev;;
esac
export AGENTOTEL_RUNTIME_VERSION="$VERSION"
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
# UUIDs used for stack/run records only need the broad RFC shape.  Project and
# checkout identities are deliberately UUIDv4 because those values are part of
# the persisted cross-process identity contract.
rand_uuid(){ od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | awk '{printf "%s-%s-%s-%s-%s\n",substr($0,1,8),substr($0,9,4),substr($0,13,4),substr($0,17,4),substr($0,21,12)}'; }
rand_uuid_v4(){
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | awk '{
    h=$0; n=index("0123456789abcdef", substr(h,17,1))-1;
    printf "%s-%s-4%s-%s%s-%s\n", substr(h,1,8), substr(h,9,4), substr(h,14,3), substr("89ab",(n%4)+1,1), substr(h,18,3), substr(h,21,12)
  }'
}
valid_uuid(){ printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
valid_uuid_v4(){ printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; }
valid_project_uuid(){ valid_uuid_v4 "$1"; }
atomic(){ tmp="$1.tmp.$$"; (umask 077; cat > "$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }

# Load only the credential role needed by the caller.  Compose is the sole
# command that needs all three values; an observed application receives only
# the ingest token and query tools receive only the query token.
credential_value(){
  f="$CFG/credentials"
  [ -e "$f" ] || die 'credential store is missing; run obs credentials ensure'
  [ ! -L "$f" ] || die 'credential symlink rejected'
  [ -f "$f" ] || die 'credential store is not a regular file'
  chmod 600 "$f"
  value=$(sed -n "s/.*\"$1\":\"\([0-9a-f][0-9a-f]*\)\".*/\1/p" "$f")
  [ -n "$value" ] || die "credential store missing $1"
  case "$value" in *[!0-9a-f]*) die "credential store has invalid $1";; esac
  printf '%s' "$value"
}
load_ingest_credential(){
  if [ -z "${GATEWAY_INGEST_TOKEN:-}" ]; then GATEWAY_INGEST_TOKEN=$(credential_value ingest_token); export GATEWAY_INGEST_TOKEN; fi
}
load_query_credential(){
  if [ -z "${GATEWAY_QUERY_TOKEN:-}" ]; then GATEWAY_QUERY_TOKEN=$(credential_value query_token); export GATEWAY_QUERY_TOKEN; fi
}
load_compose_credentials(){
  load_ingest_credential
  load_query_credential
  if [ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]; then GF_SECURITY_ADMIN_PASSWORD=$(credential_value grafana_admin_password); export GF_SECURITY_ADMIN_PASSWORD; fi
}
