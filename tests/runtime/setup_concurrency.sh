#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/libexec/agentotel/common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config/agentotel" "$tmp/data" "$tmp/state" "$tmp/run" "$tmp/bin" "$tmp/volumes"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}' >"$tmp/config/agentotel/credentials"
chmod 600 "$tmp/config/agentotel/credentials"

cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${FAKE_DOCKER_STATE:?}
volumes=$state/volumes
mkdir -p "$volumes"
sub=${1:-}; shift || :
case "$sub" in
  volume)
    op=${1:-}; shift || :
    case "$op" in
      ls)
        # Keep the first inventory slow enough to overlap both callers. The
        # setup lock, not Docker timing, must determine the result.
        sleep 0.08
        for file in "$volumes"/*; do
          [ -f "$file" ] || continue
          basename "$file"
        done
        ;;
      inspect)
        template=''; names=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -f|--format) shift; template=${1:-} ;;
            *'{{'*) : ;;
            *) names="${names}${1}
" ;;
          esac
          shift || :
        done
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          file="$volumes/$name"
          [ -f "$file" ] || exit 1
          IFS='|' read -r stack project <"$file"
          printf '%s\t%s\t%s\n' "$name" "$stack" "$project"
        done <<VOLUME_NAMES_EOF
$names
VOLUME_NAMES_EOF
        ;;
      create)
        stack=''; project=''; name=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --label)
              shift
              case "${1:-}" in
                com.agentotel.stack=*) stack=${1#*=} ;;
                com.docker.compose.project=*) project=${1#*=} ;;
              esac
              ;;
            *) name=$1 ;;
          esac
          shift || :
        done
        printf 'create %s %s %s\n' "$name" "$stack" "$project" >>"$state/creates"
        if [ ! -e "$volumes/$name" ]; then
          tmpfile="$volumes/.tmp.$$"
          printf '%s|%s\n' "$stack" "$project" >"$tmpfile"
          mv "$tmpfile" "$volumes/$name"
        fi
        printf '%s\n' "$name"
        ;;
      *) exit 90 ;;
    esac
    ;;
  *) exit 90 ;;
esac
EOF
chmod 755 "$tmp/bin/docker"
real_od=$(command -v od)
cat >"$tmp/bin/od" <<EOF
#!/bin/sh
sleep 0.05
exec "$real_od" "\$@"
EOF
chmod 755 "$tmp/bin/od"

mkdir -p "$tmp/state/agentotel/lifecycle.lock"
printf '999999||stale-setup-owner\n' >"$tmp/state/agentotel/lifecycle.lock/owner"
base_env=(HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" COMPOSE_PROJECT_NAME=concurrent-stack FAKE_DOCKER_STATE="$tmp")
PATH="$tmp/bin:$PATH" env "${base_env[@]}" "$ROOT/libexec/agentotel/setup.sh" >"$tmp/one.out" 2>"$tmp/one.err" & one=$!
PATH="$tmp/bin:$PATH" env "${base_env[@]}" "$ROOT/libexec/agentotel/setup.sh" >"$tmp/two.out" 2>"$tmp/two.err" & two=$!
wait "$one"
wait "$two"

uuid_one=$(tr -d '\n' <"$tmp/one.out")
uuid_two=$(tr -d '\n' <"$tmp/two.out")
[ "$uuid_one" = "$uuid_two" ]
printf '%s\n' "$uuid_one" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
fixture_names=$(agentotel_active_volume_names concurrent-stack)
fixture_count=$(printf '%s\n' "$fixture_names" | awk 'NF { count++ } END { print count + 0 }')
[ "$(wc -l <"$tmp/creates" | tr -d ' ')" -eq "$fixture_count" ]
while IFS= read -r name; do
  [ -n "$name" ] || continue
  line=$(cat "$tmp/volumes/$name")
  [ "$line" = "$uuid_one|concurrent-stack" ]
done <<EOF
$fixture_names
EOF
[ ! -e "$tmp/state/agentotel/setup.lock" ]
[ ! -e "$tmp/state/agentotel/stack.uuid.lock" ]
echo 'setup concurrency checks passed (serialized identity, inventory, create, and post-verify)'
