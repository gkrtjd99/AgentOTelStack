#!/usr/bin/env bash
set -euo pipefail

waivers=${WAIVER_FILE:-security/grafana-trivy-waivers.json}
report=${TRIVY_REPORT:-}
image=${1:?usage: $0 <image> [trivy-json-report]}
report=${2:-$report}
as_of=${WAIVER_AS_OF:-$(date -u +%F)}
artifacts_dir=${ARTIFACTS_DIR:-artifacts}
[[ -n "$report" && -f "$report" ]] || { echo "missing Trivy JSON report" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

expected=$(jq -r '.image' "$waivers")
[[ "$expected" =~ ^grafana/grafana@sha256:[0-9a-f]{64}$ ]] || { echo "waiver image must be an exact pinned Grafana upstream digest" >&2; exit 1; }
dockerfile=${GRAFANA_DOCKERFILE:-src/grafana/Dockerfile}
[[ -f "$dockerfile" ]] || { echo "missing Grafana Dockerfile: $dockerfile" >&2; exit 2; }
final_from=$(awk 'tolower($1) == "from" {last=$2} END {print last}' "$dockerfile")
[[ "$final_from" == "$expected" ]] || { echo "waiver image $expected does not match final Grafana Dockerfile base $final_from" >&2; exit 1; }
artifact=$(jq -r '.ArtifactName // empty' "$report")
[[ -n "$artifact" && "$artifact" == "$image" ]] || { echo "Trivy report artifact $artifact does not match requested image $image" >&2; exit 1; }
base_identity=$(jq -r '
  (.Metadata.ImageConfig.config.Labels // .Metadata.ImageConfig.Config.Labels // {}) as $l |
  if ($l["org.opencontainers.image.base.name"] // "") != "" and ($l["org.opencontainers.image.base.digest"] // "") != ""
  then ($l["org.opencontainers.image.base.name"] + "@" + $l["org.opencontainers.image.base.digest"])
  else empty end
' "$report")
[[ "$base_identity" == "$expected" ]] || { echo "Trivy report base identity $base_identity does not match exact waiver image $expected" >&2; exit 1; }
expiry=$(jq -r '.expires' "$waivers")
[[ "$expiry" > "$as_of" || "$expiry" == "$as_of" ]] || { echo "expired Grafana waiver: $expiry" >&2; exit 1; }
limit=$(date -j -v+30d -f %F "$as_of" +%F 2>/dev/null || date -d "$as_of +30 days" +%F)
[[ ! "$expiry" > "$limit" ]] || { echo "waiver expiry exceeds 30 days: $expiry" >&2; exit 1; }
for field in owner upstreamEvidence reachabilityControls; do jq -e --arg f "$field" '.[$f] | type == "string" and length > 10' "$waivers" >/dev/null || { echo "missing waiver $field" >&2; exit 1; }; done

jq -e '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length == 0' "$report" >/dev/null || { echo "CRITICAL vulnerability found" >&2; exit 1; }
mkdir -p "$artifacts_dir"
cp "$report" "$artifacts_dir/grafana-trivy-report.json"
findings=$(jq -c '.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH") | {VulnerabilityID,PkgName,InstalledVersion,FixedVersion}' "$report")
while IFS= read -r finding; do
  [[ -z "$finding" ]] && continue
  id=$(jq -r '.VulnerabilityID' <<<"$finding"); pkg=$(jq -r '.PkgName' <<<"$finding"); ver=$(jq -r '.InstalledVersion' <<<"$finding"); fix=$(jq -r '.FixedVersion' <<<"$finding")
  jq -e --arg id "$id" --arg pkg "$pkg" --arg ver "$ver" --arg fix "$fix" 'any(.waivers[]; .VulnerabilityID==$id and .PkgName==$pkg and .InstalledVersion==$ver and .FixedVersion==$fix)' "$waivers" >/dev/null || { echo "unwaived or changed HIGH: $finding" >&2; exit 1; }
done <<< "$findings"
jq -n --arg image "$image" --arg base "$base_identity" --arg expiry "$expiry" --argjson findings "$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")]' "$report")" '{image:$image,baseImage:$base,waivedResidualFindings:$findings,expires:$expiry}' > "$artifacts_dir/grafana-trivy-summary.json"
echo "Grafana Trivy waiver gate passed; residual findings are in $artifacts_dir/grafana-trivy-report.json"
