#!/bin/sh
. "$(dirname "$0")/common.sh"; mkdirs
FILE="$CFG/credentials"
read_key(){ key=$1; sed -n "s/.*\"$key\":\"\([0-9a-f][0-9a-f]*\)\".*/\1/p" "$FILE"; }
status(){ [ -e "$FILE" ] || { echo '{"status":"missing"}'; return; }; [ ! -L "$FILE" ] || die 'credential symlink rejected'; [ -f "$FILE" ] || die 'credential store is not a regular file'; chmod 600 "$FILE"; for key in ingest_token query_token grafana_admin_password; do value=$(read_key "$key"); [ -n "$value" ] || { echo '{"status":"incomplete"}'; return 1; }; done; echo '{"status":"configured"}'; }
cleanup_tmp(){
  if [ -n "${tmp:-}" ]; then
    rm -f "$tmp"
  fi
}
rotate(){
  if [ -L "$FILE" ]; then die 'credential symlink rejected'; fi
  safe_parent "$FILE"
  i=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); q=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); g=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  if [ "$i" = "$q" ] || [ "$i" = "$g" ] || [ "$q" = "$g" ]; then die 'random collision'; fi
  tmp=$(mktemp "$CFG/.credentials.XXXXXX")
  trap cleanup_tmp EXIT HUP INT TERM
  (umask 077; printf '{"ingest_token":"%s","query_token":"%s","grafana_admin_password":"%s"}\n' "$i" "$q" "$g" > "$tmp")
  chmod 600 "$tmp"; mv -f "$tmp" "$FILE"; tmp=''; trap - EXIT HUP INT TERM
  echo '{"status":"rotated"}'
}
ensure(){
  if [ ! -e "$FILE" ]; then rotate; return; fi
  [ ! -L "$FILE" ] || die 'credential symlink rejected'; [ -f "$FILE" ] || die 'credential store is not a regular file'; chmod 600 "$FILE"
  i=$(read_key ingest_token); q=$(read_key query_token); g=$(read_key grafana_admin_password)
  if [ -z "$i" ] || [ -z "$q" ]; then die 'credential store missing ingest_token or query_token'; fi
  if [ -n "$g" ]; then status; return; fi
  g=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); tmp=$(mktemp "$CFG/.credentials.XXXXXX"); trap cleanup_tmp EXIT HUP INT TERM; (umask 077; printf '{"ingest_token":"%s","query_token":"%s","grafana_admin_password":"%s"}\n' "$i" "$q" "$g" > "$tmp"); chmod 600 "$tmp"; mv -f "$tmp" "$FILE"; tmp=''; trap - EXIT HUP INT TERM; echo '{"status":"configured"}'
}
run(){
  [ "${1:-}" = -- ] || die 'usage: obs credentials run -- command [args...]'
  shift; [ "$#" -gt 0 ] || die 'credentials run requires a command'
  ensure >/dev/null
  . "$(dirname "$0")/common.sh"
  load_query_credential
  # Query helpers only need the read token. Do not leak the ingest token or
  # Grafana password inherited from the caller (or their file indirections)
  # into an arbitrary child process.
  unset GATEWAY_INGEST_TOKEN GATEWAY_INGEST_TOKEN_FILE
  unset GF_SECURITY_ADMIN_PASSWORD GF_SECURITY_ADMIN_PASSWORD_FILE
  exec "$@"
}
case "${1:-}" in rotate) rotate;; ensure) ensure;; status) status;; run) shift; run "$@";; *) die 'invalid credentials command';; esac
