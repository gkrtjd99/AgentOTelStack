#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: $0 <image> <trivy-json-report> <platform>}
report=${2:?usage: $0 <image> <trivy-json-report> <platform>}
platform=${3:?usage: $0 <image> <trivy-json-report> <platform>}
artifacts_dir=${ARTIFACTS_DIR:-artifacts}

case "$platform" in
  linux/amd64|linux/arm64) ;;
  *) echo "unsupported Grafana platform: $platform (expected linux/amd64 or linux/arm64)" >&2; exit 2 ;;
esac
[[ -f "$report" ]] || { echo "missing Trivy JSON report: $report" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

expected_arch=${platform#*/}
artifact=$(jq -r '.ArtifactName // empty' "$report")
[[ -n "$artifact" && "$artifact" == "$image" ]] || {
  echo "Trivy report artifact $artifact does not match requested image $image" >&2
  exit 1
}

actual_os=$(jq -r '.Metadata.ImageConfig.os // .Metadata.ImageConfig.OS // (if (.Metadata.OS | type) == "string" then .Metadata.OS else empty end)' "$report")
actual_arch=$(jq -r '.Metadata.ImageConfig.architecture // .Metadata.ImageConfig.Architecture // empty' "$report")
[[ "$actual_os" == linux && "$actual_arch" == "$expected_arch" ]] || {
  echo "Trivy report platform ${actual_os:-unknown}/${actual_arch:-unknown} does not match $platform" >&2
  exit 1
}

high_critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length' "$report")
if [[ "$high_critical" != 0 ]]; then
  echo "Grafana image contains $high_critical HIGH/CRITICAL vulnerabilities; zero is required" >&2
  jq -c '.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL") | {VulnerabilityID,Severity,PkgName,InstalledVersion,FixedVersion}' "$report" >&2
  exit 1
fi

mkdir -p "$artifacts_dir"
jq -n \
  --arg image "$image" \
  --arg platform "$platform" \
  --arg report "$report" \
  '{image:$image, platform:$platform, report:$report, high:0, critical:0, status:"pass"}' \
  > "$artifacts_dir/grafana-trivy-${expected_arch}-summary.json"
echo "Grafana Trivy zero HIGH/CRITICAL gate passed for $image ($platform)"
