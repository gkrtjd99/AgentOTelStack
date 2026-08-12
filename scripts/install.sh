#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
default_ver=$(cat "$ROOT/VERSION")
ver=${VERSION:-${1:-$default_ver}}
without_mcp=false
if [ "${1:-}" = --without-mcp ]; then
  without_mcp=true
  ver=${VERSION:-${2:-$default_ver}}
fi
case "$ver" in *[!A-Za-z0-9._-]*|'') echo 'invalid version' >&2; exit 2;; esac
data=${XDG_DATA_HOME:-$HOME/.local/share}/agentotel
bin=${XDG_BIN_HOME:-$HOME/.local/bin}; stage="$data/.staging-$ver-$$"
mkdir -p "$data" "$bin"; [ ! -L "$data" ] || { echo 'symlink rejected' >&2; exit 2; }
[ ! -e "$data/$ver" ] || { echo "version already installed: $ver" >&2; exit 2; }
mkdir -p "$stage" "$stage/libexec/agentotel" "$stage/assets"
if [ "$without_mcp" = false ]; then
  mkdir -p "$stage/bin"
  if ! "$ROOT/scripts/build-mcp.sh" "$stage/bin/agentotel-mcp"; then
    rm -rf "$stage"; echo 'install failed: MCP is enabled by default; install Docker or pass --without-mcp' >&2; exit 1
  fi
fi
chmod 700 "$stage" "$data"
# Runtime is self-contained: no command executed by an installed launcher reads the checkout.
cp "$ROOT"/libexec/agentotel/*.sh "$stage/libexec/agentotel/"
for d in app gateway grafana mcp otel-collector workload obs dashboards; do
  if [ -d "$ROOT/$d" ]; then
    mkdir -p "$stage/assets/$d"
    (cd "$ROOT/$d" && find . -type f -not -path './node_modules/*' -not -path './.git/*' -not -name '*.log' -exec sh -c 'mkdir -p "$1/$(dirname "$2")"; cp "$2" "$1/$2"' sh "$stage/assets/$d" {} \;)
  fi
done
cp "$ROOT/docker-compose.yml" "$stage/assets/"; [ -f "$ROOT/.env.example" ] && cp "$ROOT/.env.example" "$stage/assets/"
cp "$ROOT/bin/obs" "$stage/libexec/agentotel/obs"
printf '%s\n' "$ver" > "$stage/VERSION"; chmod 600 "$stage/VERSION"
# shellcheck disable=SC2094
(cd "$stage" && find . -type f ! -name manifest.sha256 -exec shasum -a 256 {} \; | sort > manifest.sha256); chmod 600 "$stage/manifest.sha256"
mv "$stage" "$data/$ver"
if [ -L "$data/current" ]; then old=$(readlink "$data/current"); rm -f "$data/previous"; ln -s "$old" "$data/previous.tmp.$$"; mv -f "$data/previous.tmp.$$" "$data/previous"; fi
ln -s "$ver" "$data/current.tmp.$$"; rm -f "$data/current"; mv -f "$data/current.tmp.$$" "$data/current"
cp "$ROOT/bin/obs" "$bin/obs"; chmod 700 "$bin/obs"
# Initialize distinct credentials without ever printing their values.
CFG=${XDG_CONFIG_HOME:-$HOME/.config}/agentotel; mkdir -p "$CFG"; chmod 700 "$CFG"
if [ ! -e "$CFG/credentials" ]; then "$data/current/libexec/agentotel/credentials.sh" rotate >/dev/null; fi
echo "installed $ver"
