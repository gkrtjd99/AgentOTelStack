#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_CONFIG_HOME="$t/config" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/run"
mkdir -p "$HOME" "$t/fake"

cat >"$t/credential-child" <<'EOF'
#!/bin/sh
env | grep -E '^(GATEWAY_[^=]*|GF_[^=]*)=' | sort || :
EOF
cat >"$t/run-child" <<'EOF'
#!/bin/sh
env | grep -E '^(GATEWAY_[^=]*|GF_[^=]*)=' | sort || :
EOF
chmod 755 "$t/credential-child" "$t/run-child"

# A legacy store is accepted only long enough to discard its third value.
mkdir -p "$XDG_CONFIG_HOME/agentotel"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb","grafana_admin_password":"must-not-survive"}' >"$XDG_CONFIG_HOME/agentotel/credentials"
chmod 600 "$XDG_CONFIG_HOME/agentotel/credentials"
"$root"/libexec/agentotel/credentials.sh ensure >/dev/null
grep -q '^{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}$' "$XDG_CONFIG_HOME/agentotel/credentials"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb","grafana_admin_password":"must-not-survive-again"}' >"$XDG_CONFIG_HOME/agentotel/credentials"
status=$("$root"/libexec/agentotel/credentials.sh status)
[ "$status" = '{"status":"configured"}' ]
grep -q '^{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}$' "$XDG_CONFIG_HOME/agentotel/credentials"
if grep -q 'grafana_admin_password\|must-not-survive' "$XDG_CONFIG_HOME/agentotel/credentials"; then
  echo 'legacy admin credential survived normalization' >&2
  exit 1
fi

# Deterministically hold a legacy normalization publish while rotate contends.
# The transaction lock must make rotate wait; otherwise stale legacy tokens can
# overwrite the fresh rotation after the reader has classified the file.
race_file="$XDG_CONFIG_HOME/agentotel/credentials"
race_ready="$t/race-ready"
race_allow="$t/race-allow"
mkdir -p "$t/race-bin"
real_mv=$(command -v mv)
cat >"$t/race-bin/mv" <<'EOF'
#!/bin/sh
set -eu
last=''
for arg do last=$arg; done
if [ "$last" = "$RACE_FILE" ] && [ ! -e "$RACE_READY" ]; then
  : >"$RACE_READY"
  while [ ! -e "$RACE_ALLOW" ]; do sleep .01; done
fi
exec "$REAL_MV" "$@"
EOF
chmod 755 "$t/race-bin/mv"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb","grafana_admin_password":"race-legacy"}' >"$race_file"
PATH="$t/race-bin:$PATH" RACE_FILE="$race_file" RACE_READY="$race_ready" RACE_ALLOW="$race_allow" REAL_MV="$real_mv" \
  "$root/libexec/agentotel/credentials.sh" status >"$t/race-status.out" 2>&1 &
race_status_pid=$!
for _ in $(seq 1 100); do [ -e "$race_ready" ] && break; sleep .05; done
[ -e "$race_ready" ] || { echo 'credential race did not reach normalization publish' >&2; exit 1; }
PATH="$t/race-bin:$PATH" RACE_FILE="$race_file" RACE_READY="$race_ready" RACE_ALLOW="$race_allow" REAL_MV="$real_mv" \
  "$root/libexec/agentotel/credentials.sh" rotate >"$t/race-rotate.out" 2>&1 &
race_rotate_pid=$!
sleep .1
kill -0 "$race_rotate_pid" 2>/dev/null || { echo 'rotate did not contend on credential transaction lock' >&2; exit 1; }
: >"$race_allow"
wait "$race_status_pid"
wait "$race_rotate_pid"
grep -q 'configured' "$t/race-status.out"
grep -q 'rotated' "$t/race-rotate.out"
grep -Eq '^\{"ingest_token":"[0-9a-f]+","query_token":"[0-9a-f]+"\}$' "$race_file"
if grep -q 'race-legacy\|grafana_admin_password' "$race_file"; then
  echo 'legacy credential survived transaction race' >&2
  exit 1
fi

GATEWAY_INGEST_TOKEN=caller-ingest GATEWAY_QUERY_TOKEN=caller-query \
GF_SECURITY_ADMIN_PASSWORD=caller-grafana GF_SECURITY_ADMIN_PASSWORD_FILE=caller-file \
GF_SECURITY_ADMIN_USER=caller-user GF_ANALYTICS_CHECK_FOR_UPDATES=caller-analytics \
GF_PATHS_PLUGINS=caller-plugins \
  "$root/libexec/agentotel/credentials.sh" run -- "$t/credential-child" >"$t/credential-child.env"
grep -q '^GATEWAY_QUERY_TOKEN=caller-query$' "$t/credential-child.env"
if grep -Eq '^GF_[^=]*=' "$t/credential-child.env" || grep -q 'caller-grafana\|caller-file\|caller-user\|caller-analytics\|caller-plugins' "$t/credential-child.env"; then
  echo 'query credential runner leaked retired Grafana credentials' >&2
  exit 1
fi

mkdir -p "$t/repo"
git -C "$t/repo" init -q
git -C "$t/repo" config user.email test@example.invalid
git -C "$t/repo" config user.name test
run_output=$(cd "$t/repo" && \
  GATEWAY_INGEST_TOKEN=run-ingest GATEWAY_QUERY_TOKEN=run-query \
  GF_SECURITY_ADMIN_PASSWORD=run-grafana GF_SECURITY_ADMIN_PASSWORD_FILE=run-file \
  GF_SECURITY_ADMIN_USER=run-user GF_USERS_ALLOW_SIGN_UP=run-signup \
  GF_PLUGINS_PLUGIN_ADMIN_ENABLED=run-plugin \
  AGENTOTEL_DEV_MODE=1 "$root/libexec/agentotel/run.sh" --service scrub-test -- "$t/run-child")
if printf '%s\n' "$run_output" | grep -Eq '^GF_[^=]*=|run-grafana|run-file|run-user|run-signup|run-plugin|run-ingest|run-query'; then
  echo 'obs run leaked retired Grafana or Gateway credentials' >&2
  exit 1
fi

"$root/libexec/agentotel/credentials.sh" rotate >/dev/null
grep -Eq '^\{"ingest_token":"[0-9a-f]+","query_token":"[0-9a-f]+"\}$' "$XDG_CONFIG_HOME/agentotel/credentials"
if grep -q 'grafana_admin_password' "$XDG_CONFIG_HOME/agentotel/credentials"; then
  echo 'rotated credentials contain retired key' >&2
  exit 1
fi

launcher_case="$t/launcher-case"
mkdir -p "$launcher_case/bin"
ln -s "$launcher_case/target" "$launcher_case/bin/obs"
if XDG_DATA_HOME="$launcher_case/data" XDG_BIN_HOME="$launcher_case/bin" XDG_CONFIG_HOME="$launcher_case/config" "$root/scripts/install.sh" --without-mcp 9.9.8 >"$t/launcher-symlink.out" 2>&1; then
  echo 'launcher symlink must be rejected' >&2
  exit 1
fi
grep -q 'symlink rejected: launcher' "$t/launcher-symlink.out"
mkdir -p "$t/nonregular/bin/obs"
if XDG_DATA_HOME="$t/nonregular/data" XDG_BIN_HOME="$t/nonregular/bin" XDG_CONFIG_HOME="$t/nonregular/config" "$root/scripts/install.sh" --without-mcp 9.9.7 >"$t/launcher-nonregular.out" 2>&1; then
  echo 'non-regular launcher target must be rejected' >&2
  exit 1
fi
grep -q 'not a regular file' "$t/launcher-nonregular.out"
for location in config data state runtime; do
  case "$location" in
    config) xdg_var=XDG_CONFIG_HOME; xdg_home="$t/mkdirs-config" ;;
    data) xdg_var=XDG_DATA_HOME; xdg_home="$t/mkdirs-data" ;;
    state) xdg_var=XDG_STATE_HOME; xdg_home="$t/mkdirs-state" ;;
    runtime) xdg_var=XDG_RUNTIME_DIR; xdg_home="$t/mkdirs-runtime" ;;
  esac
  mkdir -p "$xdg_home"
  ln -s "$t/real-$location" "$xdg_home/agentotel"
  if env AGENTOTEL_DEV_MODE=1 HOME="$t/home" XDG_CONFIG_HOME="$t/mkdirs-config-$location" XDG_DATA_HOME="$t/mkdirs-data-$location" XDG_STATE_HOME="$t/mkdirs-state-$location" XDG_RUNTIME_DIR="$t/mkdirs-runtime-$location" "$xdg_var=$xdg_home" "$root/bin/obs" credentials status >"$t/mkdirs-$location.out" 2>&1; then
    echo "mkdirs must reject $location symlink" >&2
    exit 1
  fi
  grep -q 'symlink rejected' "$t/mkdirs-$location.out"
done

"$root/scripts/install.sh" --without-mcp 9.9.9 >/dev/null
test "$(stat -f '%Lp' "$XDG_CONFIG_HOME/agentotel/credentials" 2>/dev/null || stat -c '%a' "$XDG_CONFIG_HOME/agentotel/credentials")" = 600
grep -Eq '^\{"ingest_token":"[0-9a-f]+","query_token":"[0-9a-f]+"\}$' "$XDG_CONFIG_HOME/agentotel/credentials"

cat >"$t/fake/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = compose ]
[ -n "${GATEWAY_INGEST_TOKEN:-}" ]
[ -n "${GATEWAY_QUERY_TOKEN:-}" ]
if env | grep -Eq '^GF_[^=]*='; then
  echo 'compose runner received retired Grafana environment' >&2
  exit 1
fi
if [ "${EXPECT_INGEST:-}" = operator-override ]; then
  [ "$GATEWAY_INGEST_TOKEN" = operator-override ]
fi
EOF
chmod 755 "$t/fake/docker"
PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose ps
if PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose config >"$t/compose-config.out" 2>&1; then
  echo 'compose config must be rejected' >&2
  exit 1
fi
grep -q 'renders credential values' "$t/compose-config.out"
if PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose convert >"$t/compose-convert.out" 2>&1; then
  echo 'compose convert must be rejected' >&2
  exit 1
fi
grep -q 'renders credential values' "$t/compose-convert.out"
GF_SECURITY_ADMIN_PASSWORD=hostile-help GF_PATHS_PLUGINS=hostile-help \
  PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose --help >"$t/compose-help.out"
grep -q 'config and convert are disabled' "$t/compose-help.out"
if GF_SECURITY_ADMIN_PASSWORD=hostile-no-args GF_USERS_ALLOW_SIGN_UP=hostile-no-args \
  PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose >"$t/compose-no-args.out" 2>&1; then
  echo 'compose without arguments unexpectedly succeeded' >&2
  exit 1
fi
if grep -Eq '^GF_[^=]*=' "$t/compose-no-args.out"; then
  echo 'compose no-argument path leaked retired Grafana environment' >&2
  exit 1
fi
EXPECT_INGEST=operator-override GATEWAY_INGEST_TOKEN=operator-override PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose ps

echo 'credential/compose lifecycle checks passed'
