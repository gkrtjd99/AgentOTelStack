#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH=; cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
report="$tmp/report.json"
artifacts="$tmp/artifacts"
image='dev-observability/grafana:ci-test-arm64'

cat >"$report" <<'JSON'
{"ArtifactName":"dev-observability/grafana:ci-test-arm64","Metadata":{"ImageConfig":{"os":"linux","architecture":"arm64"}},"Results":[]}
JSON
ARTIFACTS_DIR="$artifacts" "$root/scripts/security/verify-grafana-trivy-zero.sh" "$image" "$report" linux/arm64 >/dev/null
test -s "$artifacts/grafana-trivy-arm64-summary.json"

sed 's/arm64/amd64/g' "$report" >"$tmp/amd64.json"
ARTIFACTS_DIR="$artifacts" "$root/scripts/security/verify-grafana-trivy-zero.sh" \
  dev-observability/grafana:ci-test-amd64 "$tmp/amd64.json" linux/amd64 >/dev/null

cat >"$tmp/high.json" <<'JSON'
{"ArtifactName":"dev-observability/grafana:ci-test-arm64","Metadata":{"ImageConfig":{"os":"linux","architecture":"arm64"}},"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-test","Severity":"HIGH","PkgName":"test","InstalledVersion":"1.0"}]}]}
JSON
if ARTIFACTS_DIR="$artifacts" "$root/scripts/security/verify-grafana-trivy-zero.sh" "$image" "$tmp/high.json" linux/arm64 >/dev/null 2>&1; then
  echo 'grafana-trivy-zero-test: HIGH finding was accepted' >&2
  exit 1
fi

cat >"$tmp/critical.json" <<'JSON'
{"ArtifactName":"dev-observability/grafana:ci-test-arm64","Metadata":{"ImageConfig":{"os":"linux","architecture":"arm64"}},"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-test","Severity":"CRITICAL","PkgName":"test","InstalledVersion":"1.0"}]}]}
JSON
if ARTIFACTS_DIR="$artifacts" "$root/scripts/security/verify-grafana-trivy-zero.sh" "$image" "$tmp/critical.json" linux/arm64 >/dev/null 2>&1; then
  echo 'grafana-trivy-zero-test: CRITICAL finding was accepted' >&2
  exit 1
fi

if ARTIFACTS_DIR="$artifacts" "$root/scripts/security/verify-grafana-trivy-zero.sh" \
  dev-observability/grafana:ci-test-arm64 "$tmp/amd64.json" linux/arm64 >/dev/null 2>&1; then
  echo 'grafana-trivy-zero-test: wrong architecture was accepted' >&2
  exit 1
fi

forbidden_scan='--ignore-un'; forbidden_scan+='fixed'
forbidden_policy='waiv'; forbidden_policy+='er'
if rg -n -- "$forbidden_scan|$forbidden_policy" "$root/scripts/security/verify-grafana-trivy-zero.sh"; then
  echo 'grafana-trivy-zero-test: forbidden exception behavior remains' >&2
  exit 1
fi
echo 'grafana-trivy-zero-test: PASS (zero HIGH/CRITICAL and architecture checks)'
