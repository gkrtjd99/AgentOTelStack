#!/bin/sh
# Verify installer hash-tool selection, failure propagation, and staging cleanup.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
real_sha256sum=$(command -v sha256sum || true)
t=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-hash-test.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM

make_path() {
  mode=$1
  path="$t/path-$mode"
  mkdir -p "$path"
  # Keep a deliberately small command path so hash availability is controlled;
  # the installer itself uses /bin/sh for its shebang.
  for command in awk basename cat chmod cp dirname find grep id ln mkdir mktemp mv od readlink rm sed sort tr wc; do
    real=$(command -v "$command")
    ln -s "$real" "$path/$command"
  done
  ln -s /bin/sh "$path/sh"
  case "$mode" in
    sha256sum-only)
      cat >"$path/sha256sum" <<'EOF'
#!/bin/sh
printf 'sha256sum\n' >>"${HASH_LOG:?}"
exec "${REAL_SHA256SUM:?}" "$@"
EOF
      chmod +x "$path/sha256sum"
      ;;
    shasum-only)
      ln -s /usr/bin/shasum "$path/shasum"
      ;;
    failing-hash)
      cat >"$path/sha256sum" <<'EOF'
#!/bin/sh
printf 'sha256sum-failing\n' >>"${HASH_LOG:?}"
exit 17
EOF
      chmod +x "$path/sha256sum"
      ;;
    neither)
      :
      ;;
    *) echo "unknown mode: $mode" >&2; exit 2;;
  esac
  printf '%s\n' "$path"
}

run_success() {
  mode=$1; version=$2
  path=$(make_path "$mode")
  base="$t/$mode"
  mkdir -p "$base/home"
  REAL_SHA256SUM="$real_sha256sum" HASH_LOG="$base/hash.log" HOME="$base/home" XDG_DATA_HOME="$base/data" \
    XDG_BIN_HOME="$base/bin" XDG_CONFIG_HOME="$base/config" PATH="$path" \
    "$root/scripts/install.sh" --without-mcp "$version" >/"$base/out"
  test -L "$base/data/agentotel/current"
  test -s "$base/data/agentotel/current/manifest.sha256"
  case "$mode" in
    sha256sum-only) test -s "$base/hash.log"; grep -Fq sha256sum "$base/hash.log" ;;
    shasum-only) : ;;
  esac
}

run_failure() {
  mode=$1; version=$2
  path=$(make_path "$mode")
  base="$t/$mode"
  mkdir -p "$base/home"
  if REAL_SHA256SUM="$real_sha256sum" HASH_LOG="$base/hash.log" HOME="$base/home" XDG_DATA_HOME="$base/data" \
    XDG_BIN_HOME="$base/bin" XDG_CONFIG_HOME="$base/config" PATH="$path" \
    "$root/scripts/install.sh" --without-mcp "$version" >"$base/out" 2>&1; then
    echo "$mode unexpectedly passed" >&2
    exit 1
  fi
  test ! -e "$base/data/agentotel/$version"
  if [ -d "$base/data/agentotel" ] && find "$base/data/agentotel" -maxdepth 1 -name '.staging-*' -print -quit | grep -q .; then
    echo "$mode left staging residue" >&2
    exit 1
  fi
}

run_success sha256sum-only 4.0.0
run_success shasum-only 4.0.1
run_failure neither 4.0.2
run_failure failing-hash 4.0.3
grep -Fq 'neither sha256sum nor shasum is available' "$t/neither/out"
grep -Fq 'manifest generation failed' "$t/failing-hash/out"
echo 'installer hash-tool fixtures: PASS (sha256sum, shasum, neither, and failing tool)'
