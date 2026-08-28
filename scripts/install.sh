#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
# Preserve the caller's version request before common.sh supplies its runtime
# fallback VERSION=unknown. Command-line versions remain effective when the
# installer is invoked directly from a checkout.
requested_version=${VERSION:-}
requested_arg1=${1:-}
requested_arg2=${2:-}
# Reuse the portable owner-aware lock used by runtime lifecycle operations.
# Installation does not use an exec path that could bypass its release trap.
. "$ROOT/libexec/agentotel/common.sh"
default_ver=$(cat "$ROOT/VERSION")
if [ -n "$requested_version" ]; then
  ver=$requested_version
elif [ "$requested_arg1" = --without-mcp ]; then
  ver=${requested_arg2:-$default_ver}
else
  ver=${requested_arg1:-$default_ver}
fi
without_mcp=false
if [ "$requested_arg1" = --without-mcp ]; then
  without_mcp=true
fi
case "$ver" in *[!A-Za-z0-9._-]*|'') echo 'invalid version' >&2; exit 2;; esac
data=${XDG_DATA_HOME:-$HOME/.local/share}/agentotel
bin=${XDG_BIN_HOME:-$HOME/.local/bin}; stage="$data/.staging-$ver-$$"
[ ! -L "$data" ] || { echo 'symlink rejected: data directory' >&2; exit 2; }
[ ! -L "$bin" ] || { echo 'symlink rejected: bin directory' >&2; exit 2; }
mkdir -p "$data" "$bin"

# The installer is the bootstrap boundary: keep its per-version lock here
# rather than relying on a common.sh from an already-installed runtime. mkdir is
# the portable atomic claim; the owner record permits dead-owner recovery while
# PID plus process-start matching prevents PID reuse from stealing a live lock.
install_lock_process_start(){ ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }
install_lock_mtime(){
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || printf '0\n'
}
install_lock_reclaim(){
  lock_dir=$1
  [ -d "$lock_dir" ] || return 1
  [ ! -L "$lock_dir" ] || return 1
  if [ -L "$lock_dir/owner" ]; then
    return 1
  elif [ -f "$lock_dir/owner" ]; then
    IFS='|' read -r lock_pid lock_start lock_token <"$lock_dir/owner" || return 1
    case "$lock_pid" in ''|*[!0-9]*) return 1;; esac
    [ -n "$lock_token" ] || return 1
    if kill -0 "$lock_pid" 2>/dev/null; then
      current_start=$(install_lock_process_start "$lock_pid")
      [ -n "$lock_start" ] && [ -n "$current_start" ] && [ "$lock_start" != "$current_start" ] || return 1
    fi
    rm -f "$lock_dir/owner" || return 1
  else
    created=$(install_lock_mtime "$lock_dir"); now=$(date +%s)
    case "$created:$now" in *[!0-9:]*|'0:'*) return 1;; esac
    [ $((now - created)) -ge 1 ] || return 1
  fi
  rmdir "$lock_dir" 2>/dev/null
}
install_lock_acquire(){
  install_lock_dir=$1
  install_lock_i=0
  [ ! -L "$install_lock_dir" ] || { echo 'symlink rejected: per-version install lock' >&2; exit 2; }
  while :; do
    if (umask 077; mkdir "$install_lock_dir") 2>/dev/null; then
      chmod 700 "$install_lock_dir" || { rmdir "$install_lock_dir" 2>/dev/null || :; echo 'unable to initialize per-version install lock' >&2; exit 1; }
      install_lock_token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      install_lock_start=$(install_lock_process_start "$$")
      install_lock_owner_tmp="$install_lock_dir/owner.tmp.$$"
      if (umask 077; printf '%s|%s|%s\n' "$$" "$install_lock_start" "$install_lock_token" >"$install_lock_owner_tmp") && chmod 600 "$install_lock_owner_tmp" && mv -f "$install_lock_owner_tmp" "$install_lock_dir/owner"; then
        return 0
      fi
      rm -f "$install_lock_owner_tmp" "$install_lock_dir/owner"
      rmdir "$install_lock_dir" 2>/dev/null || :
      echo 'unable to initialize per-version install lock' >&2
      exit 1
    fi
    [ ! -L "$install_lock_dir" ] || { echo 'symlink rejected: per-version install lock' >&2; exit 2; }
    if install_lock_reclaim "$install_lock_dir"; then continue; fi
    install_lock_i=$((install_lock_i+1))
    [ "$install_lock_i" -lt 2000 ] || { echo "install busy for version $ver" >&2; exit 75; }
    sleep .01
  done
}
install_lock_release(){
  lock_dir=$1; token=$2
  [ -d "$lock_dir" ] || return 0
  [ ! -L "$lock_dir" ] || return 1
  [ ! -L "$lock_dir/owner" ] || return 1
  [ -f "$lock_dir/owner" ] || return 1
  IFS='|' read -r lock_pid lock_start lock_actual_token <"$lock_dir/owner" || return 1
  [ "$lock_pid" = "$$" ] && [ "$lock_actual_token" = "$token" ] || return 1
  rm -f "$lock_dir/owner" || return 1
  rmdir "$lock_dir"
}
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
CFG=${XDG_CONFIG_HOME:-$HOME/.config}/agentotel
[ ! -L "$CFG" ] || { echo 'symlink rejected: config directory' >&2; exit 2; }
mkdir -p "$CFG"; chmod 700 "$CFG"
install_lock="$data/.install-$ver.lock"
install_lock_acquire "$install_lock"
cleanup(){
  if [ -n "${stage:-}" ] && [ -d "$stage" ]; then
    rm -rf "$stage"
  fi
  if [ -n "${manifest_raw:-}" ]; then rm -f "$manifest_raw"; fi
  if [ -n "${manifest_tmp:-}" ]; then rm -f "$manifest_tmp"; fi
  if [ -n "${current_tmp:-}" ]; then rm -f "$current_tmp"; fi
  if [ -n "${previous_tmp:-}" ]; then rm -f "$previous_tmp"; fi
  if [ -n "${launcher_tmp:-}" ]; then rm -f "$launcher_tmp"; fi
  install_lock_release "$install_lock" "${install_lock_token:-}" >/dev/null 2>&1 || :
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# All destination and pointer checks happen while holding this version lock.
[ ! -e "$data/$ver" ] || { echo "version already installed: $ver (another installer won)" >&2; exit 2; }
validate_pointer "$data/current"
validate_pointer "$data/previous"
old=''
if [ -L "$data/current" ]; then
  old=$(readlink "$data/current")
fi
# A SIGKILL can leave a stage behind with its dead owner's lock.  Once this
# process owns the version lock, old stages for this version are unambiguously
# abandoned and safe to remove before creating a fresh one.
for stale_stage in "$data/.staging-$ver-"*; do
  [ -e "$stale_stage" ] || [ -L "$stale_stage" ] || continue
  rm -rf "$stale_stage"
done
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
for d in app backend-health dashboard gateway mcp otel-collector; do
  if [ -d "$ROOT/src/$d" ]; then
    mkdir -p "$stage/assets/src/$d"
    mcp_binary_path=./not-mcp-binary
    [ "$d" = mcp ] && mcp_binary_path=./mcp
    (cd "$ROOT/src/$d" && find . \
      \( -type d \( -name node_modules -o -name .git -o -name .cache -o -name .trivy-cache -o -name .npm -o -name .yarn -o -name .pnpm-store -o -name .nyc_output -o -name __pycache__ -o -name artifacts -o -name coverage -o -name test-results -o -name playwright-report -o -name playwright-artifacts -o -name bin -o -name build -o -name dist -o -name tmp -o -name vendor \) -prune \) -o \
      -type f -not -path "$mcp_binary_path" -not -name '*.log' -not -name '*.out' -not -name '*.prof' -not -name '*.test' -not -name '*.coverprofile' -not -name '*.coverage' -not -name '*.tmp' -not -name '.DS_Store' -not -name '.eslintcache' -not -name '.stylelintcache' -not -name 'current.tmp.*' -not -name 'previous.tmp.*' -not -name 'manifest.sha256.*' -not -name '*.install.tmp.*' \
      -exec sh -c 'dest=$1; shift; for src do mkdir -p "$dest/$(dirname "$src")"; cp "$src" "$dest/$src"; done' sh "$stage/assets/src/$d" {} +)
  fi
done
for d in workload obs; do
  if [ -d "$ROOT/$d" ]; then
    mkdir -p "$stage/assets/$d"
    (cd "$ROOT/$d" && find . \
      \( -type d \( -name node_modules -o -name .git -o -name .cache -o -name .trivy-cache -o -name .npm -o -name .yarn -o -name .pnpm-store -o -name .nyc_output -o -name __pycache__ -o -name artifacts -o -name coverage -o -name test-results -o -name playwright-report -o -name playwright-artifacts -o -name tmp \) -prune \) -o \
      -type f -not -name '*.log' -not -name '*.out' -not -name '*.prof' -not -name '*.test' -not -name '*.coverprofile' -not -name '*.coverage' -not -name '*.tmp' -not -name '.DS_Store' -not -name '.eslintcache' -not -name '.stylelintcache' -not -name 'current.tmp.*' -not -name 'previous.tmp.*' -not -name 'manifest.sha256.*' -not -name '*.install.tmp.*' \
      -exec sh -c 'dest=$1; shift; for src do mkdir -p "$dest/$(dirname "$src")"; cp "$src" "$dest/$src"; done' sh "$stage/assets/$d" {} +)
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
  "$stage/assets/src/backend-health/Dockerfile.victoriatraces" \
  "$stage/assets/src/dashboard/Dockerfile" \
  "$stage/assets/src/dashboard/LICENSE" \
  "$stage/assets/src/dashboard/go.mod" \
  "$stage/assets/src/dashboard/README.md" \
  "$stage/assets/src/dashboard/cmd/dashboard/main.go" \
  "$stage/assets/src/dashboard/cmd/dashboard/main_test.go" \
  "$stage/assets/src/dashboard/internal/proxy/proxy.go" \
  "$stage/assets/src/dashboard/internal/proxy/proxy_test.go" \
  "$stage/assets/src/dashboard/internal/ui/ui.go" \
  "$stage/assets/src/dashboard/internal/ui/ui_test.go" \
  "$stage/assets/src/dashboard/internal/ui/static/index.html" \
  "$stage/assets/src/dashboard/internal/ui/static/assets/app.js" \
  "$stage/assets/src/dashboard/internal/ui/static/assets/request-state.js" \
  "$stage/assets/src/dashboard/internal/ui/static/assets/styles.css"; do
  [ -f "$required" ] || { echo "install asset missing: $required" >&2; exit 1; }
done
# Generate the manifest with a portable SHA-256 implementation. Keep the
# hashing and sorting statuses separate: `find ... | sort` can otherwise report
# sort's success while a failing hash command was swallowed by the pipeline.
hash_tool=
if command -v sha256sum >/dev/null 2>&1; then
  hash_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  hash_tool=shasum
else
  echo 'install failed: neither sha256sum nor shasum is available' >&2
  exit 1
fi
manifest_raw="$stage/manifest.sha256.raw.$$"
manifest_tmp="$stage/manifest.sha256.tmp.$$"
set +e
if [ "$hash_tool" = sha256sum ]; then
  (cd "$stage" && find . -type f ! -name manifest.sha256 ! -name 'manifest.sha256.*' -exec sha256sum {} + >"$manifest_raw")
else
  (cd "$stage" && find . -type f ! -name manifest.sha256 ! -name 'manifest.sha256.*' -exec shasum -a 256 {} + >"$manifest_raw")
fi
hash_status=$?
set -e
[ "$hash_status" -eq 0 ] || { echo 'install failed: SHA-256 manifest generation failed' >&2; exit 1; }
[ -s "$manifest_raw" ] || { echo 'install failed: generated manifest is empty' >&2; exit 1; }
if ! sort "$manifest_raw" >"$manifest_tmp"; then
  echo 'install failed: unable to sort SHA-256 manifest' >&2
  exit 1
fi
[ -s "$manifest_tmp" ] || { echo 'install failed: sorted manifest is empty' >&2; exit 1; }
mv -f "$manifest_tmp" "$stage/manifest.sha256"
manifest_tmp=''
rm -f "$manifest_raw"
manifest_raw=''
chmod 600 "$stage/manifest.sha256"
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
