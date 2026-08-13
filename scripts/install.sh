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
[ ! -L "$data" ] || { echo 'symlink rejected: data directory' >&2; exit 2; }
[ ! -L "$bin" ] || { echo 'symlink rejected: bin directory' >&2; exit 2; }
mkdir -p "$data" "$bin"
if [ -L "$bin/obs" ]; then
  echo 'symlink rejected: launcher' >&2
  exit 2
fi
if [ -e "$bin/obs" ] && [ ! -f "$bin/obs" ]; then
  echo 'launcher target is not a regular file' >&2
  exit 2
fi
validate_pointer(){
  pointer=$1
  if [ -e "$pointer" ] || [ -L "$pointer" ]; then
    if [ ! -L "$pointer" ]; then
      echo "runtime pointer is not a symlink: $pointer" >&2
      exit 2
    fi
    target=$(readlink "$pointer")
    case "$target" in
      ''|/*|*/*|.|..|*[!A-Za-z0-9._-]*)
        echo "invalid runtime pointer target: $pointer" >&2
        exit 2
        ;;
    esac
    if [ ! -d "$data/$target" ] || [ -L "$data/$target" ]; then
      echo "runtime pointer target is missing or unsafe: $pointer" >&2
      exit 2
    fi
  fi
}
validate_pointer "$data/current"
validate_pointer "$data/previous"
[ ! -e "$data/$ver" ] || { echo "version already installed: $ver" >&2; exit 2; }
old=''
if [ -L "$data/current" ]; then
  old=$(readlink "$data/current")
fi
CFG=${XDG_CONFIG_HOME:-$HOME/.config}/agentotel
[ ! -L "$CFG" ] || { echo 'symlink rejected: config directory' >&2; exit 2; }
mkdir -p "$CFG"; chmod 700 "$CFG"
cleanup(){
  if [ -n "${stage:-}" ] && [ -d "$stage" ]; then
    rm -rf "$stage"
  fi
  if [ -n "${current_tmp:-}" ]; then rm -f "$current_tmp"; fi
  if [ -n "${previous_tmp:-}" ]; then rm -f "$previous_tmp"; fi
  if [ -n "${launcher_tmp:-}" ]; then rm -f "$launcher_tmp"; fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$stage" "$stage/libexec/agentotel" "$stage/assets"
if [ "$without_mcp" = false ]; then
  mkdir -p "$stage/bin"
  if ! VERSION="$ver" "$ROOT/scripts/build-mcp.sh" "$stage/bin/agentotel-mcp"; then
    rm -rf "$stage"; echo 'install failed: MCP is enabled by default; install Docker or pass --without-mcp' >&2; exit 1
  fi
fi
chmod 700 "$stage" "$data"
# Runtime is self-contained: no command executed by an installed launcher reads the checkout.
cp "$ROOT"/libexec/agentotel/*.sh "$stage/libexec/agentotel/"
for d in app backend-health gateway grafana mcp otel-collector dashboards; do
  if [ -d "$ROOT/src/$d" ]; then
    mkdir -p "$stage/assets/src/$d"
    mcp_binary_path=./not-mcp-binary
    [ "$d" = mcp ] && mcp_binary_path=./mcp
    (cd "$ROOT/src/$d" && find . \
      \( -type d \( -name node_modules -o -name .git -o -name .cache -o -name bin -o -name build -o -name coverage -o -name dist -o -name tmp -o -name vendor \) -prune \) -o \
      -type f -not -path "$mcp_binary_path" -not -name '*.log' -not -name '*.out' -not -name '*.prof' -not -name '*.test' \
      -exec sh -c 'dest=$1; shift; for src do mkdir -p "$dest/$(dirname "$src")"; cp "$src" "$dest/$src"; done' sh "$stage/assets/src/$d" {} +)
  fi
done
for d in workload obs; do
  if [ -d "$ROOT/$d" ]; then
    mkdir -p "$stage/assets/$d"
    (cd "$ROOT/$d" && find . -type f -not -path './node_modules/*' -not -path './.git/*' -not -name '*.log' -exec sh -c 'dest=$1; shift; for src do mkdir -p "$dest/$(dirname "$src")"; cp "$src" "$dest/$src"; done' sh "$stage/assets/$d" {} +)
  fi
done
cp "$ROOT/docker-compose.yml" "$stage/assets/"; [ -f "$ROOT/.env.example" ] && cp "$ROOT/.env.example" "$stage/assets/"
cp "$ROOT/bin/obs" "$stage/libexec/agentotel/obs"
printf '%s\n' "$ver" > "$stage/VERSION"; chmod 600 "$stage/VERSION"
for required in \
  "$stage/assets/docker-compose.yml" \
  "$stage/assets/src/backend-health/Dockerfile.collector" \
  "$stage/assets/src/backend-health/Dockerfile.victorialogs" \
  "$stage/assets/src/backend-health/Dockerfile.victoriametrics" \
  "$stage/assets/src/backend-health/Dockerfile.victoriatraces"; do
  [ -f "$required" ] || { echo "install asset missing: $required" >&2; exit 1; }
done
# shellcheck disable=SC2094
(cd "$stage" && find . -type f ! -name manifest.sha256 -exec shasum -a 256 {} + | sort > manifest.sha256); chmod 600 "$stage/manifest.sha256"
# Validate/create credentials while the new runtime is still staging. No
# version pointer or launcher is changed until this succeeds.
"$stage/libexec/agentotel/credentials.sh" ensure >/dev/null
current_tmp="$data/current.tmp.$$"
launcher_tmp="$bin/obs.tmp.$$"
if [ -e "$current_tmp" ] || [ -L "$current_tmp" ] || [ -e "$launcher_tmp" ] || [ -L "$launcher_tmp" ]; then
  echo 'install temporary path already exists' >&2
  exit 1
fi
ln -s "$ver" "$current_tmp"
if [ -n "$old" ]; then
  previous_tmp="$data/previous.tmp.$$"
  if [ -e "$previous_tmp" ] || [ -L "$previous_tmp" ]; then
    echo 'install temporary path already exists' >&2
    exit 1
  fi
  ln -s "$old" "$previous_tmp"
fi
cp "$ROOT/bin/obs" "$launcher_tmp"; chmod 700 "$launcher_tmp"
# Commit only after all asset, pointer, credential, and launcher validation has
# succeeded. Each individual replacement is atomic; failed pre-commit checks
# leave current/previous and the installed launcher untouched.
mv "$stage" "$data/$ver"; stage=''
if [ -n "${previous_tmp:-}" ]; then rm -f "$data/previous"; mv "$previous_tmp" "$data/previous"; previous_tmp=''; fi
rm -f "$data/current"; mv "$current_tmp" "$data/current"; current_tmp=''
mv -f "$launcher_tmp" "$bin/obs"; launcher_tmp=''
echo "installed $ver"
