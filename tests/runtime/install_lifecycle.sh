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
if ! (cd "$XDG_DATA_HOME/agentotel/current" && sha256sum -c manifest.sha256 >/dev/null 2>&1); then
  (cd "$XDG_DATA_HOME/agentotel/current" && shasum -a 256 -c manifest.sha256 >/dev/null)
fi
"$t/source-clone/scripts/install.sh" 1.0.1 >/dev/null
test "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 1.0.1
test "$(readlink "$XDG_DATA_HOME/agentotel/previous")" = 1.0.0
mv "$t/source-clone" "$t/renamed-clone"
rm -rf "$t/renamed-clone"
test -x "$XDG_DATA_HOME/agentotel/current/bin/agentotel-mcp"
echo 'runtime MCP lifecycle checks passed'
