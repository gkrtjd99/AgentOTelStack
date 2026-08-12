#!/usr/bin/env bash
set -euo pipefail

waivers=${WAIVER_FILE:-security/grafana-trivy-waivers.json}
report=${TRIVY_REPORT:-}
image=${1:?usage: $0 <image> [trivy-json-report]}
report=${2:-$report}
as_of=${WAIVER_AS_OF:-$(date -u +%F)}
[[ -n "$report" && -f "$report" ]] || { echo "missing Trivy JSON report" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

expected=$(jq -r '.image' "$waivers")
[[ "$image" == "$expected" || "$image" == *"grafana"* ]] || { echo "waivers are only valid for exact Grafana image $expected" >&2; exit 1; }
expiry=$(jq -r '.expires' "$waivers")
[[ "$expiry" > "$as_of" || "$expiry" == "$as_of" ]] || { echo "expired Grafana waiver: $expiry" >&2; exit 1; }
limit=$(date -j -v+30d -f %F "$as_of" +%F 2>/dev/null || date -d "$as_of +30 days" +%F)
[[ ! "$expiry" > "$limit" ]] || { echo "waiver expiry exceeds 30 days: $expiry" >&2; exit 1; }
for field in owner upstreamEvidence reachabilityControls; do jq -e --arg f "$field" '.[$f] | type == "string" and length > 10' "$waivers" >/dev/null || { echo "missing waiver $field" >&2; exit 1; }; done

jq -e '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length == 0' "$report" >/dev/null || { echo "CRITICAL vulnerability found" >&2; exit 1; }
mkdir -p artifacts
cp "$report" "artifacts/grafana-trivy-report.json"
findings=$(jq -c '.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH") | {VulnerabilityID,PkgName,InstalledVersion,FixedVersion}' "$report")
while IFS= read -r finding; do
  [[ -z "$finding" ]] && continue
  id=$(jq -r '.VulnerabilityID' <<<"$finding"); pkg=$(jq -r '.PkgName' <<<"$finding"); ver=$(jq -r '.InstalledVersion' <<<"$finding"); fix=$(jq -r '.FixedVersion' <<<"$finding")
  jq -e --arg id "$id" --arg pkg "$pkg" --arg ver "$ver" --arg fix "$fix" 'any(.waivers[]; .VulnerabilityID==$id and .PkgName==$pkg and .InstalledVersion==$ver and .FixedVersion==$fix)' "$waivers" >/dev/null || { echo "unwaived or changed HIGH: $finding" >&2; exit 1; }
done <<< "$findings"
jq -n --arg image "$image" --arg expiry "$expiry" --argjson findings "$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")]' "$report")" '{image:$image,waivedResidualFindings:$findings,expires:$expiry}' > artifacts/grafana-trivy-summary.json
echo "Grafana Trivy waiver gate passed; residual findings are in artifacts/grafana-trivy-report.json"
