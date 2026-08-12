#!/bin/sh
. "$(dirname "$0")/common.sh"; mkdirs
FILE="$CFG/credentials"
status(){ [ -f "$FILE" ] || { echo '{"status":"missing"}'; return; }; [ ! -L "$FILE" ] || die 'credential symlink rejected'; chmod 600 "$FILE"; echo '{"status":"configured"}'; }
rotate(){ [ ! -L "$FILE" ] || die 'credential symlink rejected'; i=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); q=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); [ "$i" != "$q" ] || die 'random collision'; (umask 077; printf '{"ingest_token":"%s","query_token":"%s"}\n' "$i" "$q" > "$FILE"); chmod 600 "$FILE"; echo '{"status":"rotated"}'; }
case "${1:-}" in rotate) rotate;; status) status;; *) die 'invalid credentials command';; esac
