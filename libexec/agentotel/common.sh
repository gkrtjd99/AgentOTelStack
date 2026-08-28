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

# Portable cooperative locks. The directory creation is the atomic claim; the
# owner record makes a SIGKILL-released lock recoverable without `flock`, which
# is not available on every supported host. A live owner is never reclaimed:
# compare both PID liveness and the process start marker when the platform
# provides one. The owner token prevents a reused PID from releasing a lock it
# no longer owns.
lock_process_start(){ ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }
lock_mtime(){
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || printf '0\n'
}
lock_owner_live(){
  lock_dir=$1
  [ -f "$lock_dir/owner" ] || return 2
  IFS='|' read -r lock_pid lock_start lock_token <"$lock_dir/owner" || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1;; esac
  [ -n "$lock_token" ] || return 1
  kill -0 "$lock_pid" 2>/dev/null || return 1
  current_start=$(lock_process_start "$lock_pid")
  [ -z "$lock_start" ] || [ -z "$current_start" ] || [ "$lock_start" = "$current_start" ] || return 1
  return 0
}
lock_reclaim_stale(){
  lock_dir=$1
  [ -d "$lock_dir" ] || return 1
  if [ -L "$lock_dir/owner" ]; then
    return 1
  elif [ -f "$lock_dir/owner" ]; then
    IFS='|' read -r lock_pid lock_start lock_token <"$lock_dir/owner" || return 1
    case "$lock_pid" in ''|*[!0-9]*) return 1;; esac
    [ -n "$lock_token" ] || return 1
    if kill -0 "$lock_pid" 2>/dev/null; then
      # A live PID is normally contention. If its process-start marker differs,
      # however, the PID was reused and the recorded owner is stale. When a
      # platform does not expose a marker, remain conservative and do not steal.
      current_start=$(lock_process_start "$lock_pid")
      [ -n "$lock_start" ] && [ -n "$current_start" ] && [ "$lock_start" != "$current_start" ] || return 1
    fi
    rm -f "$lock_dir/owner" || return 1
  else
    # There is a tiny mkdir-to-owner window. Only reclaim an owner-less lock
    # after a full second, which also recovers a process killed in that window.
    lock_created=$(lock_mtime "$lock_dir"); lock_now=$(date +%s)
    case "$lock_created:$lock_now" in *[!0-9:]*|'0:'*) return 1;; esac
    [ $((lock_now - lock_created)) -ge 1 ] || return 1
  fi
  rmdir "$lock_dir" 2>/dev/null
}
lock_acquire(){
  lock_dir=$1; lock_label=${2:-lock}; lock_limit=${3:-1000}
  [ ! -L "$lock_dir" ] || die "symlink rejected: $lock_label lock"
  lock_parent=$(dirname "$lock_dir")
  [ ! -L "$lock_parent" ] || die "symlink rejected: $lock_label lock parent"
  lock_i=0
  while :; do
    # The lock directory and owner record are state, not a user-visible cache.
    # Create the directory under a restrictive umask before publishing the
    # owner record, so a process killed at any point cannot leave readable PID
    # metadata behind.
    if (umask 077; mkdir "$lock_dir") 2>/dev/null; then
      chmod 700 "$lock_dir" || { rmdir "$lock_dir" 2>/dev/null || :; die "unable to initialize $lock_label lock"; }
      lock_token=$(rand_uuid)
      lock_start=$(lock_process_start "$$")
      lock_owner_tmp="$lock_dir/owner.tmp.$$"
      if (umask 077; printf '%s|%s|%s\n' "$$" "$lock_start" "$lock_token" >"$lock_owner_tmp") && chmod 600 "$lock_owner_tmp" && mv -f "$lock_owner_tmp" "$lock_dir/owner"; then
        # Callers in the sourced shell consume this transaction token for an
        # owner-checked release; it is intentionally not exported to children.
        # shellcheck disable=SC2034
        AGENTOTEL_LOCK_TOKEN=$lock_token
        return 0
      fi
      rm -f "$lock_owner_tmp" "$lock_dir/owner"
      rmdir "$lock_dir" 2>/dev/null || :
      die "unable to initialize $lock_label lock"
    fi
    [ ! -L "$lock_dir" ] || die "symlink rejected: $lock_label lock"
    if lock_reclaim_stale "$lock_dir"; then continue; fi
    lock_i=$((lock_i+1))
    [ "$lock_i" -lt "$lock_limit" ] || die "$lock_label busy" 75
    sleep .01
  done
}
lock_release(){
  lock_dir=$1; lock_token=$2
  [ -d "$lock_dir" ] || return 0
  [ ! -L "$lock_dir" ] || return 1
  [ ! -L "$lock_dir/owner" ] || return 1
  [ -f "$lock_dir/owner" ] || return 1
  IFS='|' read -r lock_pid lock_start lock_actual_token <"$lock_dir/owner" || return 1
  [ "$lock_pid" = "$$" ] && [ "$lock_actual_token" = "$lock_token" ] || return 1
  rm -f "$lock_dir/owner" || return 1
  rmdir "$lock_dir"
}
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
# Canonical active volume contract. Keep this newline-delimited so callers can
# consume names with `while IFS= read -r`, never word splitting or eval.
agentotel_active_volume_suffixes(){
  printf '%s\n' \
    otelcol-queue \
    victorialogs-data \
    victoriametrics-data \
    victoriatraces-data
}
agentotel_active_volume_names(){
  agentotel_volume_project=$1
  agentotel_active_volume_suffixes | while IFS= read -r agentotel_volume_suffix; do
    printf '%s_%s\n' "$agentotel_volume_project" "$agentotel_volume_suffix"
  done
}

# Load only the credential role needed by the caller. Compose receives the
# two Gateway tokens; observed applications receive only ingest and query tools
# receive only query.
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
}
# Retired Grafana variables must never cross an agentotel runner boundary.  Use
# the environment names rather than values so secrets are neither printed nor
# copied into another shell while the inherited environment is scrubbed.
scrub_retired_grafana_env(){
  while IFS= read -r name; do
    [ -n "$name" ] && unset "$name"
  done <<EOF
$(env | sed -n 's/^\(GF_[A-Za-z0-9_]*\)=.*/\1/p')
EOF
  :
}
