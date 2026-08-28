#!/usr/bin/env bash
# Strict, release-quality checks that can run from a checkout. This is not a
# claim of hosted parity: GitHub-only live integration, API/status checks, and
# workflow-history/release-publication checks are listed explicitly below.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GO_IMAGE='golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36'
NODE_IMAGE='node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32'
SHELLCHECK_IMAGE='koalaman/shellcheck-alpine:v0.10.0@sha256:5921d946dac740cbeec2fb1c898747b6105e585130cc7f0602eec9a10f7ddb63'
TRIVY_IMAGE='aquasec/trivy:0.73.0@sha256:7cced7cae583819fc7806d4cbc0dbbc7cad18b99f7d3e235192e6da8c091045c'
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentotel-ci-local.XXXXXX")"
GATE_TRACE="$TMP_DIR/gates.invoked"
cleanup() {
  local status=$? cleanup_failed=0 image
  if [[ -n "${LOCAL_IMAGE_TAGS:-}" ]] && command -v docker >/dev/null 2>&1; then
    # Remove only images this invocation built; never prune caches or unrelated
    # developer images. Cleanup failures must not be silently swallowed.
    for image in $LOCAL_IMAGE_TAGS; do
      if ! docker image rm -f "$image" >/dev/null 2>&1; then
        printf 'CI local cleanup: failed to remove exact image %s\n' "$image" >&2
        cleanup_failed=1
      fi
    done
  fi
  rm -rf "$TMP_DIR"
  if (( status != 0 )); then return "$status"; fi
  return "$cleanup_failed"
}
trap cleanup EXIT HUP INT TERM
pass=0
fail=0

run_gate() {
  local name=$1; shift
  local output="$TMP_DIR/$name.out"
  # Record the invocation before execution so a failing gate is still visible
  # in the final manifest comparison; textual presence alone is insufficient.
  printf '%s\n' "$name" >>"$GATE_TRACE"
  if "$@" >"$output" 2>&1; then
    printf 'PASS %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    sed -n '1,240p' "$output" >&2 || true
    fail=$((fail + 1))
  fi
}

shell_syntax() {
  find obs libexec scripts workload tests -type f -name '*.sh' -exec bash -n {} +
  bash -n bin/obs
}
run_gate gate-coverage ./scripts/check-ci-gate-coverage.sh
run_gate gate-coverage-fixture bash tests/runtime/ci_gate_coverage.sh
run_gate shell-syntax shell_syntax
run_gate release-version ./scripts/verify-release-version.sh
run_gate release-version-fixture bash tests/runtime/release_version.sh
run_gate doc-contract ./scripts/test-doc-contract.sh
run_gate json-schemas python3 -c 'import json,pathlib; [json.loads(p.read_text()) for p in pathlib.Path("src/gateway/schemas").glob("*.json")]'
run_gate overview-cli bash tests/cli/overview_contract.sh
run_gate dashboard-make-targets bash tests/runtime/dashboard_make_targets.sh
run_gate dashboard-readiness bash tests/runtime/dashboard_readiness.sh

dashboard_js() {
  if command -v node >/dev/null 2>&1; then
    node --test "$ROOT/src/dashboard/internal/ui/app_state_test.js"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT/src/dashboard:/repo" -w /repo/internal/ui "$NODE_IMAGE" node --test app_state_test.js
  else
    echo 'Node and Docker are both unavailable for Dashboard JavaScript tests' >&2
    return 1
  fi
}
run_gate dashboard-js dashboard_js
run_gate e2e-command-contract bash tests/runtime/e2e_command_contract.sh
run_gate e2e-trace-readiness bash tests/runtime/e2e_trace_readiness.sh
run_gate gofmt-contract bash tests/runtime/gofmt_contract.sh
run_gate storage-pressure ./scripts/test-storage-pressure.sh
run_gate security ./scripts/test-security.sh
run_gate cardinality ./scripts/test-cardinality.sh
run_gate image-provenance ./scripts/verify-image-provenance.sh
run_gate image-provenance-contract bash tests/runtime/image_provenance.sh
run_gate identity bash tests/runtime/identity_concurrency.sh
run_gate lock-recovery bash tests/runtime/lock_recovery.sh
run_gate setup-concurrency bash tests/runtime/setup_concurrency.sh
run_gate lifecycle-concurrency bash tests/runtime/lifecycle_concurrency.sh
run_gate compose-project bash tests/runtime/compose_project_identity.sh
run_gate compose-network bash tests/runtime/compose_network_contract.sh
run_gate ci-port-selection bash tests/runtime/ci_port_selection.sh
run_gate credentials-compose bash tests/runtime/credentials_compose.sh
run_gate reset-hermetic bash tests/runtime/reset_hermetic.sh
run_gate shell-call-counts bash tests/runtime/shell_call_counts.sh
run_gate ci-cleanup bash tests/runtime/ci_cleanup.sh
run_gate ci-supply-chain-cleanup bash tests/runtime/ci_supply_chain_cleanup.sh
run_gate install-lifecycle bash tests/runtime/install_lifecycle.sh
run_gate install-hash-tools bash tests/runtime/install_hash_tools.sh
run_gate image-tags-rollback bash tests/runtime/image_tags_rollback.sh
run_gate release-source bash tests/release/source_archive.sh
run_gate authoritative bash tests/runtime/authoritative.sh

shellcheck_gate() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -e SC1091 bin/obs obs/*.sh libexec/agentotel/*.sh scripts/*.sh workload/*.sh
    find tests -type f -name '*.sh' -exec shellcheck -x -e SC1091 {} +
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/src" -w /src "$SHELLCHECK_IMAGE" sh -ec '
      set -eu
      shellcheck -x -e SC1091 bin/obs obs/*.sh libexec/agentotel/*.sh scripts/*.sh workload/*.sh
      find tests -type f -name "*.sh" -exec shellcheck -x -e SC1091 {} +
    '
  else
    echo 'shellcheck is unavailable and no pinned Docker fallback exists' >&2
    return 1
  fi
}
run_gate shellcheck shellcheck_gate

compose_config() {
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required for strict Compose checks' >&2; return 1; }
  AGENTOTEL_STACK_UUID=00000000-0000-4000-8000-000000000001 \
  AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
  GATEWAY_INGEST_TOKEN=ci-local-ingest GATEWAY_QUERY_TOKEN=ci-local-query \
    docker compose --profile demo --profile dashboard config >/dev/null
}
run_gate compose-config compose_config
run_gate backend-health ./scripts/test-backend-health.sh

go_module() {
  local module=$1
  if command -v go >/dev/null 2>&1; then
    "$ROOT/scripts/check-gofmt.sh" "$ROOT/src/$module"
    (cd "$ROOT/src/$module" && go test ./... && go test -race ./... && go vet ./... && go build ./...)
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/repo" -w "/repo/src/$module" "$GO_IMAGE" \
      sh -ec "/repo/scripts/check-gofmt.sh /repo/src/$module && go test ./... && go test -race ./... && go vet ./... && go build ./..."
  else
    echo "Go and Docker are both unavailable for $module" >&2
    return 1
  fi
}
run_gate mcp-go go_module mcp
run_gate gateway-go go_module gateway
run_gate dashboard-go go_module dashboard

mcp_cross_build() {
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required for pinned MCP cross-builds' >&2; return 1; }
  local tmp="$TMP_DIR/mcp"
  mkdir -p "$tmp"
  for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
    local os=${target%/*} arch=${target#*/}
    ./scripts/build-mcp.sh "$tmp/agentotel-mcp-$os-$arch" "$os" "$arch"
    test -s "$tmp/agentotel-mcp-$os-$arch"
  done
}
run_gate mcp-cross-build mcp_cross_build

node_app() {
  if command -v npm >/dev/null 2>&1; then
    (cd src/app && npm ci --ignore-scripts --no-audit && npm test)
    (cd src/app && npm audit --package-lock-only --audit-level=high)
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/repo" -w /repo/src/app "$NODE_IMAGE" \
      sh -ec 'npm ci --ignore-scripts --no-audit && npm test && npm audit --package-lock-only --audit-level=high'
  else
    echo 'npm and Docker are both unavailable for app checks' >&2
    return 1
  fi
}
run_gate app-tests-audit node_app

e2e_audit() {
  if command -v npm >/dev/null 2>&1; then
    (cd e2e && npm ci --ignore-scripts --no-audit && npm audit --audit-level=high)
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/repo" -w /repo/e2e "$NODE_IMAGE" \
      sh -ec 'npm ci --ignore-scripts --no-audit && npm audit --audit-level=high'
  else
    echo 'npm and Docker are both unavailable for E2E dependency audit' >&2
    return 1
  fi
}
run_gate e2e-audit e2e_audit

# Build and scan exact local image tags when Docker is usable. The resolved
# Compose image set is the source of truth, so the pinned BusyBox queue-init
# image and every other runtime image are represented without a waiver list.
local_image_scan() {
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required for local image scan' >&2; return 1; }
  docker info >/dev/null 2>&1 || { echo 'Docker daemon is unavailable for local image scan' >&2; return 1; }
  local suffix="ci-local-$$"
  local project="agentotel-ci-local-$$"
  export LOCAL_IMAGE_TAGS="dev-observability/app:$suffix dev-observability/gateway:$suffix dev-observability/dashboard:$suffix dev-observability/victorialogs:v1.52.0-health-$suffix dev-observability/victoriametrics:v1.150.0-health-$suffix dev-observability/victoriatraces:v0.11.0-health-$suffix dev-observability/otel-collector:v0.159.0-health-$suffix"
  COMPOSE_PROJECT_NAME="$project" AGENTOTEL_RUNTIME_VERSION="$suffix" \
  AGENTOTEL_STACK_UUID=00000000-0000-4000-8000-000000000001 \
  AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
  GATEWAY_INGEST_TOKEN=ci-local-ingest GATEWAY_QUERY_TOKEN=ci-local-query \
    docker compose --profile demo --profile dashboard build app gateway dashboard victorialogs victoriametrics victoriatraces otel-collector
  local resolved="$TMP_DIR/local-images.json"
  COMPOSE_PROJECT_NAME="$project" AGENTOTEL_RUNTIME_VERSION="$suffix" \
  AGENTOTEL_STACK_UUID=00000000-0000-4000-8000-000000000001 \
  AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
  GATEWAY_INGEST_TOKEN=ci-local-ingest GATEWAY_QUERY_TOKEN=ci-local-query \
    docker compose --profile demo --profile dashboard config --format json >"$resolved"
  images=()
  while IFS= read -r image; do
    [ -n "$image" ] && images+=("$image")
  done < <(jq -r '.services[] | .image // empty' "$resolved" | sort -u)
  ((${#images[@]} > 0))
  printf '%s\n' "${images[@]}" | grep -Fxq 'busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
  for image in "${images[@]}"; do
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE" image --exit-code 1 --severity HIGH,CRITICAL "$image"
  done
}
run_gate local-image-trivy local_image_scan

run_gate git-diff-check git diff --check

# Re-run the inventory checker with the trace collected by run_gate. This is a
# runtime assertion that every manifest gate was reached exactly once, rather
# than merely appearing in this source file.
gate_trace_output="$TMP_DIR/gate-invocation-trace.out"
if ./scripts/check-ci-gate-coverage.sh --trace "$GATE_TRACE" >"$gate_trace_output" 2>&1; then
  printf 'PASS gate-invocation-trace\n'
  pass=$((pass + 1))
else
  printf 'FAIL gate-invocation-trace\n' >&2
  sed -n '1,240p' "$gate_trace_output" >&2 || true
  fail=$((fail + 1))
fi

printf 'CI local strict gates: PASS=%d FAIL=%d\n' "$pass" "$fail"
echo 'Hosted-only (not local parity): live integration workload/backend outage, GitHub CI-status gate, actionlint, history/repository gitleaks policy, and release publication/API checks.'
if (( fail != 0 )); then
  exit 1
fi
