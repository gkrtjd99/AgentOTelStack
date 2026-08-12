#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd); cd "$root"
pass=0; fail=0; skip=0
gate(){ name=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS $name"; pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi; }
gate shell-syntax sh -c 'find obs libexec scripts workload tests -type f -name "*.sh" -print0 | xargs -0 -n1 bash -n; bash -n bin/obs'
gate release-version ./scripts/verify-release-version.sh
gate json-schemas python3 -c 'import json,pathlib; [json.loads(p.read_text()) for p in pathlib.Path("gateway/schemas").glob("*.json")]'
gate storage-pressure ./scripts/test-storage-pressure.sh
gate security ./scripts/test-security.sh
gate cardinality ./scripts/test-cardinality.sh
gate image-provenance ./scripts/verify-image-provenance.sh
gate identity bash tests/runtime/identity_concurrency.sh
if command -v shellcheck >/dev/null 2>&1; then gate shellcheck shellcheck -x -e SC1091 bin/obs obs/*.sh libexec/agentotel/*.sh scripts/*.sh workload/*.sh; elif command -v docker >/dev/null 2>&1; then gate shellcheck docker run --rm -v "$root:/src" -w /src koalaman/shellcheck-alpine:v0.10.0 shellcheck -x -e SC1091 bin/obs obs/*.sh libexec/agentotel/*.sh scripts/*.sh workload/*.sh; else echo 'SKIP shellcheck (shellcheck and docker not installed)'; skip=$((skip+1)); fi
if command -v docker >/dev/null 2>&1; then gate compose-config sh -c 'AGENTOTEL_STACK_UUID=00000000-0000-4000-8000-000000000001 GATEWAY_INGEST_TOKEN=ci-ingest-token GATEWAY_QUERY_TOKEN=ci-query-token GF_SECURITY_ADMIN_PASSWORD=ci-grafana-password docker compose --profile demo --profile dashboard config >/dev/null'; else echo 'SKIP compose-config (docker not installed)'; skip=$((skip+1)); fi
if command -v npm >/dev/null 2>&1; then
  gate app-audit sh -c 'cd app && npm audit --package-lock-only --audit-level=high'
  gate e2e-audit sh -c 'cd e2e && npm install --package-lock-only --ignore-scripts >/dev/null && npm audit --audit-level=high'
else echo 'SKIP npm-audit (npm not installed)'; skip=$((skip+1)); fi
gate git-diff-check git diff --check
echo "CI local parity: PASS=$pass FAIL=$fail SKIP=$skip"
test "$fail" -eq 0
