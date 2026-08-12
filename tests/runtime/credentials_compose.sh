#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_CONFIG_HOME="$t/config" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/run"
mkdir -p "$HOME" "$t/fake"

cat >"$t/credential-child" <<'EOF'
#!/bin/sh
env | grep -E '^(GATEWAY_|GF_SECURITY_)' | sort
EOF
chmod 755 "$t/credential-child"
GATEWAY_INGEST_TOKEN=caller-ingest GATEWAY_QUERY_TOKEN=caller-query GF_SECURITY_ADMIN_PASSWORD=caller-grafana \
  "$root/libexec/agentotel/credentials.sh" run -- "$t/credential-child" >"$t/credential-child.env"
grep -q '^GATEWAY_QUERY_TOKEN=caller-query$' "$t/credential-child.env"
if grep -Eq '^(GATEWAY_INGEST_TOKEN|GF_SECURITY_ADMIN_PASSWORD)=' "$t/credential-child.env"; then
  echo 'query credential runner leaked non-query credentials' >&2
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
cat >"$t/fake/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = compose ]
[ -n "${GATEWAY_INGEST_TOKEN:-}" ]
[ -n "${GATEWAY_QUERY_TOKEN:-}" ]
[ -n "${GF_SECURITY_ADMIN_PASSWORD:-}" ]
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
PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose --help >"$t/compose-help.out"
grep -q 'config and convert are disabled' "$t/compose-help.out"
EXPECT_INGEST=operator-override GATEWAY_INGEST_TOKEN=operator-override PATH="$t/fake:$PATH" "$XDG_BIN_HOME/obs" compose ps
echo 'credential/compose lifecycle checks passed'
