#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_STATE_HOME="$t/state" XDG_CONFIG_HOME="$t/config" XDG_RUNTIME_DIR="$t/run"; mkdir -p "$HOME"
"$root/scripts/install.sh" 1.0.0 >/dev/null; "$root/scripts/install.sh" 1.0.1 >/dev/null
[ "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 1.0.1 ]; [ "$(readlink "$XDG_DATA_HOME/agentotel/previous")" = 1.0.0 ]
"$XDG_BIN_HOME/obs" runtime rollback >/dev/null; [ "$(readlink "$XDG_DATA_HOME/agentotel/current")" = 1.0.0 ]
git init -q "$t/repo"; cd "$t/repo"; git config user.email test@example.invalid; git config user.name test; "$root/bin/obs" init >/dev/null; "$root/bin/obs" project rekey >/dev/null; "$root/bin/obs" source-state | grep -q checkout_id
echo 'runtime authoritative checks passed'
