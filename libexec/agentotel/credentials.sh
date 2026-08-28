#!/bin/sh
. "$(dirname "$0")/common.sh"; mkdirs
FILE="$CFG/credentials"
credential_lock="$STATE/credentials.lock"
credential_lock_begin(){
  lock_acquire "$credential_lock" credentials 1000
  credential_lock_token=$AGENTOTEL_LOCK_TOKEN
  trap credential_lock_cleanup EXIT
  trap 'exit 1' HUP INT TERM
}
credential_lock_end(){
  trap - EXIT HUP INT TERM
  lock_release "$credential_lock" "$credential_lock_token" >/dev/null 2>&1 || :
}
credential_lock_cleanup(){
  credential_lock_rc=$?
  trap - EXIT HUP INT TERM
  lock_release "$credential_lock" "${credential_lock_token:-}" >/dev/null 2>&1 || :
  exit "$credential_lock_rc"
}
read_key(){ key=$1; sed -n "s/.*\"$key\":\"\([0-9a-f][0-9a-f]*\)\".*/\1/p" "$FILE"; }
store_kind(){
  [ "$(wc -l <"$FILE" | tr -d ' ')" -le 1 ] || return 1
  if grep -Eq '^\{"ingest_token":"[0-9a-f]+","query_token":"[0-9a-f]+"\}$' "$FILE"; then
    printf '%s\n' canonical
    return 0
  fi
  # This is the only legacy shape accepted.  Its third value is deliberately
  # never read, exported, printed, or reused; it is discarded on normalization.
  if grep -Eq '^\{"ingest_token":"[0-9a-f]+","query_token":"[0-9a-f]+","grafana_admin_password":"[^"]*"\}$' "$FILE"; then
    printf '%s\n' legacy
    return 0
  fi
  return 1
}
write_tokens(){
  i=$1; q=$2
  if [ -z "$i" ] || [ -z "$q" ]; then
    die 'credential store missing ingest_token or query_token'
  fi
  tmp=$(mktemp "$CFG/.credentials.XXXXXX") || die 'unable to create credential store temporary file'
  if ! (umask 077; printf '{"ingest_token":"%s","query_token":"%s"}\n' "$i" "$q" >"$tmp"); then
    rm -f "$tmp"
    die 'unable to write credential store temporary file'
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; die 'unable to secure credential store temporary file'; }
  if ! mv -f "$tmp" "$FILE"; then
    rm -f "$tmp"
    die 'unable to publish credential store'
  fi
  tmp=''
}
read_tokens(){
  kind=$(store_kind) || return 1
  i=$(read_key ingest_token); q=$(read_key query_token)
  [ -n "$i" ] && [ -n "$q" ] || return 1
  CREDENTIAL_KIND=$kind CREDENTIAL_INGEST=$i CREDENTIAL_QUERY=$q
}
status(){
  credential_lock_begin
  if [ ! -e "$FILE" ]; then
    credential_lock_end
    echo '{"status":"missing"}'
    return
  fi
  [ ! -L "$FILE" ] || die 'credential symlink rejected'
  [ -f "$FILE" ] || die 'credential store is not a regular file'
  chmod 600 "$FILE"
  if ! read_tokens; then
    credential_lock_end
    echo '{"status":"incomplete"}'
    return 1
  fi
  if [ "$CREDENTIAL_KIND" = legacy ]; then
    # Classification, the final read, and normalization all stay inside the
    # same lock; a rotate cannot be overwritten by a stale legacy reader.
    if ! read_tokens; then die 'credential store changed during status'; fi
    [ "$CREDENTIAL_KIND" = legacy ] || :
    write_tokens "$CREDENTIAL_INGEST" "$CREDENTIAL_QUERY"
  fi
  echo '{"status":"configured"}'
  credential_lock_end
}
rotate(){
  credential_lock_begin
  if [ -L "$FILE" ]; then die 'credential symlink rejected'; fi
  safe_parent "$FILE"
  i=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); q=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  [ "$i" != "$q" ] || die 'random collision'
  write_tokens "$i" "$q"
  echo '{"status":"rotated"}'
  credential_lock_end
}
ensure(){
  credential_lock_begin
  if [ ! -e "$FILE" ]; then
    safe_parent "$FILE"
    i=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); q=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    [ "$i" != "$q" ] || die 'random collision'
    write_tokens "$i" "$q"
    echo '{"status":"configured"}'
    credential_lock_end
    return
  fi
  [ ! -L "$FILE" ] || die 'credential symlink rejected'
  [ -f "$FILE" ] || die 'credential store is not a regular file'
  chmod 600 "$FILE"
  if ! read_tokens; then die 'credential store missing ingest_token or query_token'; fi
  if [ "$CREDENTIAL_KIND" = legacy ]; then
    # Re-read after classification while the transaction lock is held.
    if ! read_tokens; then die 'credential store changed during ensure'; fi
    [ "$CREDENTIAL_KIND" = legacy ] || :
    write_tokens "$CREDENTIAL_INGEST" "$CREDENTIAL_QUERY"
  fi
  echo '{"status":"configured"}'
  credential_lock_end
}
run(){
  [ "${1:-}" = -- ] || die 'usage: obs credentials run -- command [args...]'
  shift; [ "$#" -gt 0 ] || die 'credentials run requires a command'
  ensure >/dev/null
  . "$(dirname "$0")/common.sh"
  load_query_credential
  # Query helpers only need the read token. Do not leak the ingest token
  # inherited from the caller (or its file indirection) into a child process.
  unset GATEWAY_INGEST_TOKEN GATEWAY_INGEST_TOKEN_FILE
  scrub_retired_grafana_env
  exec "$@"
}
case "${1:-}" in rotate) rotate;; ensure) ensure;; status) status;; run) shift; run "$@";; *) die 'invalid credentials command';; esac
