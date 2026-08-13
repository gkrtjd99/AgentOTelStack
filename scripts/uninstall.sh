#!/bin/sh
set -eu
data=${XDG_DATA_HOME:-$HOME/.local/share}/agentotel
bin=${XDG_BIN_HOME:-$HOME/.local/bin}
mode=${1:-launcher}
case "$mode" in
  launcher) [ ! -L "$data" ] || { echo 'refusing symlink data dir' >&2; exit 2; }; [ ! -L "$bin" ] || { echo 'refusing symlink bin dir' >&2; exit 2; }; rm -f "$bin/obs"; [ ! -L "$data/current" ] || rm -f "$data/current"; echo 'agentotel launcher removed; runtime and telemetry preserved' ;;
  purge-runtime) [ ! -L "$data" ] || { echo 'refusing symlink data dir' >&2; exit 2; }; [ ! -L "$bin" ] || { echo 'refusing symlink bin dir' >&2; exit 2; }; rm -f "$data/current" "$data/previous"; for d in "$data"/*; do [ -d "$d" ] || continue; case "${d##*/}" in .*) continue;; esac; [ ! -L "$d" ] || { echo 'refusing symlink runtime' >&2; exit 2; }; rm -rf "$d"; done; rm -f "$bin/obs"; echo 'agentotel runtimes removed; configuration, state, and telemetry volumes preserved';;
  *) echo 'usage: uninstall.sh [launcher|purge-runtime]' >&2; exit 2;;
esac
