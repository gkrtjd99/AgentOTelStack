#!/bin/sh
set -eu

root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
export HOME="$t/home" XDG_DATA_HOME="$t/data" XDG_BIN_HOME="$t/bin" XDG_CONFIG_HOME="$t/config"
mkdir -p "$HOME" "$t/fake"

# The fake Docker executable records the selected runtime and compose file but
# never contacts Docker or mutates the real stack/volumes.
cat >"$t/fake/docker" <<'EOF'
#!/bin/sh
set -eu
{
  printf 'runtime=%s\n' "${AGENTOTEL_RUNTIME_VERSION:-}"
  printf 'compose_file=%s\n' "${COMPOSE_FILE:-}"
  printf 'args='
  printf '%s ' "$@"
  printf '\n'
} >"$FAKE_DOCKER_LOG"
EOF
chmod 755 "$t/fake/docker"

# PERF-012 reproduction: before this contract, both versions rendered the
# same gateway/backend-health image references. A build of 1.0.1 could then be
# reused after rollback to 1.0.0. Install two self-contained runtimes in an
# isolated XDG store and assert that each now renders a disjoint image set.
"$root/scripts/install.sh" --without-mcp 1.0.0 >/dev/null
"$root/scripts/install.sh" --without-mcp 2.0.0 >/dev/null

assert_runtime_images(){
  version=$1
  compose_file=$2
  rendered="$t/rendered-$version.yml"
  sed "s/\${AGENTOTEL_RUNTIME_VERSION:-dev}/$version/g" "$compose_file" >"$rendered"
  grep -Fq "image: dev-observability/gateway:$version" "$rendered"
  grep -Fq "image: dev-observability/app:$version" "$rendered"
  grep -Fq "image: dev-observability/dashboard:$version" "$rendered"
  test "$(grep -Fc 'image: dev-observability/dashboard:' "$rendered")" -eq 1
  if grep -Eqi 'image: dev-observability/(grafana|dashboard-lite):' "$rendered"; then
    echo "retired dashboard image remains in $compose_file" >&2
    exit 1
  fi
  grep -Fq "image: dev-observability/victorialogs:v1.52.0-health-$version" "$rendered"
  grep -Fq "image: dev-observability/victoriametrics:v1.150.0-health-$version" "$rendered"
  grep -Fq "image: dev-observability/victoriatraces:v0.11.0-health-$version" "$rendered"
  grep -Fq "image: dev-observability/otel-collector:v0.159.0-health-$version" "$rendered"
  if grep -Eq 'image: dev-observability/(app|dashboard|gateway):dev' "$rendered"; then
    echo "locally built image is not runtime-specific: $compose_file" >&2
    exit 1
  fi
}

export PATH="$t/fake:$PATH" FAKE_DOCKER_LOG="$t/current.log"
"$XDG_BIN_HOME/obs" compose up -d
grep -Fq 'runtime=2.0.0' "$FAKE_DOCKER_LOG"
grep -Fq '/current/assets/docker-compose.yml' "$FAKE_DOCKER_LOG"
assert_runtime_images 2.0.0 "$XDG_DATA_HOME/agentotel/2.0.0/assets/docker-compose.yml"

"$XDG_BIN_HOME/obs" runtime rollback >/dev/null
export FAKE_DOCKER_LOG="$t/rollback.log"
"$XDG_BIN_HOME/obs" compose up -d
grep -Fq 'runtime=1.0.0' "$FAKE_DOCKER_LOG"
grep -Fq '/current/assets/docker-compose.yml' "$FAKE_DOCKER_LOG"
assert_runtime_images 1.0.0 "$XDG_DATA_HOME/agentotel/1.0.0/assets/docker-compose.yml"

# Explicit checkout development remains usable and selects the checkout
# VERSION rather than requiring an installed pointer or Docker image registry.
unset COMPOSE_FILE
export AGENTOTEL_DEV_MODE=1 FAKE_DOCKER_LOG="$t/checkout.log"
"$root/bin/obs" compose up -d
grep -Fq "runtime=$(cat "$root/VERSION")" "$FAKE_DOCKER_LOG"
grep -Fq 'args=compose up -d ' "$FAKE_DOCKER_LOG"

echo 'runtime image tag rollback checks passed'
