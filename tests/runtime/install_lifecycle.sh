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
for context in app backend-health gateway grafana; do
  test -d "$runtime/assets/$context"
done
test -f "$runtime/assets/otel-collector/config.yaml"
for dockerfile in collector victorialogs victoriametrics victoriatraces; do
  test -f "$runtime/assets/backend-health/Dockerfile.$dockerfile"
done
grep -q 'context: ./backend-health' "$runtime/assets/docker-compose.yml"
if ! (cd "$XDG_DATA_HOME/agentotel/current" && sha256sum -c manifest.sha256 >/dev/null 2>&1); then
  (cd "$XDG_DATA_HOME/agentotel/current" && shasum -a 256 -c manifest.sha256 >/dev/null)
fi
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
