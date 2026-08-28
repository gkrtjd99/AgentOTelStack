#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_CONFIG_HOME="$t/config"
mkdir -p "$HOME"
cp -R "$root" "$t/source-clone"
"$t/source-clone/scripts/install.sh" 1.0.0 >/dev/null
test -x "$XDG_DATA_HOME/agentotel/current/bin/agentotel-mcp"
test -s "$XDG_DATA_HOME/agentotel/current/manifest.sha256"
runtime="$XDG_DATA_HOME/agentotel/current"
test -f "$runtime/assets/docker-compose.yml"
for context in src/app src/backend-health src/dashboard src/gateway; do
  test -d "$runtime/assets/$context"
done
# The installed asset is a runtime-only payload, not a source checkout.
for forbidden_asset in Makefile scripts docs; do
  test ! -e "$runtime/assets/$forbidden_asset"
  test ! -L "$runtime/assets/$forbidden_asset"
done
for libexec_script in \
  common.sh compose.sh credentials.sh dispatch.sh doctor.sh gateway.sh \
  project.sh query.sh reset.sh run.sh setup.sh storage.sh volumes.sh; do
  test -f "$runtime/libexec/agentotel/$libexec_script"
done
test -f "$runtime/assets/src/dashboard/README.md"
test -f "$runtime/assets/src/otel-collector/config.yaml"
for dashboard_asset in \
  Dockerfile LICENSE go.mod README.md \
  cmd/dashboard/main.go cmd/dashboard/main_test.go \
  internal/proxy/proxy.go internal/proxy/proxy_test.go \
  internal/ui/ui.go internal/ui/ui_test.go \
  internal/ui/static/index.html \
  internal/ui/static/assets/app.js internal/ui/static/assets/request-state.js \
  internal/ui/static/assets/styles.css; do
  test -f "$runtime/assets/src/dashboard/$dashboard_asset"
done
for dockerfile in collector victorialogs victoriametrics victoriatraces; do
  test -f "$runtime/assets/src/backend-health/Dockerfile.$dockerfile"
done
grep -q 'context: ./src/backend-health' "$runtime/assets/docker-compose.yml"
if ! (cd "$XDG_DATA_HOME/agentotel/current" && sha256sum -c manifest.sha256 >/dev/null 2>&1); then
  (cd "$XDG_DATA_HOME/agentotel/current" && shasum -a 256 -c manifest.sha256 >/dev/null)
fi
optional_test_clone="$t/optional-test-clone"
optional_home="$t/optional-home" optional_data="$t/optional-data" optional_bin="$t/optional-bin" optional_config="$t/optional-config"
mkdir -p "$optional_home"
cp -R "$root" "$optional_test_clone"
rm -f "$optional_test_clone/src/dashboard/internal/ui/app_state_test.js"
HOME="$optional_home" XDG_DATA_HOME="$optional_data" XDG_BIN_HOME="$optional_bin" XDG_CONFIG_HOME="$optional_config" \
  "$optional_test_clone/scripts/install.sh" --without-mcp 1.0.4 >/dev/null
test -d "$optional_data/agentotel/1.0.4/assets/src/dashboard/internal/ui"
test ! -e "$optional_data/agentotel/1.0.4/assets/src/dashboard/internal/ui/app_state_test.js"
rm -rf "$optional_test_clone"
incomplete_clone="$t/incomplete-clone"
cp -R "$root" "$incomplete_clone"
rm -f "$incomplete_clone/src/dashboard/internal/ui/static/assets/styles.css" \
  "$incomplete_clone/src/dashboard/internal/ui/static/assets/request-state.js"
if "$incomplete_clone/scripts/install.sh" --without-mcp 1.0.05 >"$t/incomplete.out" 2>&1; then
  echo 'install accepted an incomplete dashboard module' >&2
  exit 1
fi
test ! -e "$XDG_DATA_HOME/agentotel/1.0.05"
rm -rf "$incomplete_clone"
"$t/source-clone/scripts/install.sh" 1.0.1 >/dev/null
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 1.0.1
test "$(readlink "$XDG_DATA_HOME/agentotel/previous")" = 1.0.0
launcher_hash=$(shasum -a 256 "$XDG_BIN_HOME/obs" | awk '{print $1}')
current_before=$(readlink "$XDG_DATA_HOME/agentotel/current")
previous_before=$(readlink "$XDG_DATA_HOME/agentotel/previous")
printf '%s\n' '{malformed credentials' > "$XDG_CONFIG_HOME/agentotel/credentials"
if "$t/source-clone/scripts/install.sh" 1.0.2 >"$t/malformed.out" 2>&1; then
  echo 'malformed credentials must abort install' >&2
  exit 1
fi
test ! -e "$XDG_DATA_HOME/agentotel/1.0.2"
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = "$current_before"
test "$(readlink "$XDG_DATA_HOME/agentotel/previous")" = "$previous_before"
test "$(shasum -a 256 "$XDG_BIN_HOME/obs" | awk '{print $1}')" = "$launcher_hash"
if find "$XDG_DATA_HOME/agentotel" -maxdepth 1 -name '.staging-*' -print -quit | grep -q .; then
  echo 'staging directory leaked after failed install' >&2
  exit 1
fi

# Existing pointer entries are immutable and must be safe relative symlinks.
pointer_case(){
  name=$1; mode=$2; pd="$t/pointer-$name"; ph="$pd/home"; pdat="$pd/data"; pbin="$pd/bin"; pcfg="$pd/config"
  mkdir -p "$ph" "$pdat" "$pbin" "$pcfg"
  HOME="$ph" XDG_DATA_HOME="$pdat" XDG_BIN_HOME="$pbin" XDG_CONFIG_HOME="$pcfg" "$root/scripts/install.sh" --without-mcp 3.0.0 >/dev/null
  rm -f "$pdat/agentotel/current" "$pdat/agentotel/previous"
  case "$mode" in
    regular-current) printf 'not-a-link\n' > "$pdat/agentotel/current" ;;
    regular-previous) ln -s 3.0.0 "$pdat/agentotel/current"; printf 'not-a-link\n' > "$pdat/agentotel/previous" ;;
    absolute) ln -s /tmp/agentotel-external "$pdat/agentotel/current" ;;
    nested) ln -s nested/3.0.0 "$pdat/agentotel/current" ;;
  esac
  if HOME="$ph" XDG_DATA_HOME="$pdat" XDG_BIN_HOME="$pbin" XDG_CONFIG_HOME="$pcfg" "$root/scripts/install.sh" --without-mcp 3.0.1 >"$pd/out" 2>&1; then
    echo "unsafe $mode pointer must abort install" >&2
    exit 1
  fi
  test ! -e "$pdat/agentotel/3.0.1"
}
pointer_case regular-current regular-current
pointer_case regular-previous regular-previous
pointer_case absolute absolute
pointer_case nested nested

# Restore a usable store before the clone-independence check.
rm -f "$XDG_CONFIG_HOME/agentotel/credentials"
"$t/source-clone/scripts/install.sh" 1.0.2 >/dev/null
mv "$t/source-clone" "$t/renamed-clone"
rm -rf "$t/renamed-clone"
test -x "$XDG_DATA_HOME/agentotel/current/bin/agentotel-mcp"
echo 'runtime MCP lifecycle checks passed'
