#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
report="$tmp/report.json"
artifacts="$tmp/artifacts"
expected_digest='sha256:ab9a06d495291c7ba210426b62e9056dba6046d0945f7e9af041f3ff29b4c7fe'
cat >"$tmp/waiver.json" <<'JSON'
{"image":"grafana/grafana@sha256:ab9a06d495291c7ba210426b62e9056dba6046d0945f7e9af041f3ff29b4c7fe","expires":"2026-08-30","owner":"platform-security","upstreamEvidence":"verified upstream pinned image evidence","reachabilityControls":"dashboard is isolated and anonymous access is disabled","waivers":[]}
JSON
cat >"$report" <<'JSON'
{"ArtifactName":"local-grafana:test","Metadata":{"ImageConfig":{"config":{"Labels":{"org.opencontainers.image.base.name":"grafana/grafana","org.opencontainers.image.base.digest":"sha256:ab9a06d495291c7ba210426b62e9056dba6046d0945f7e9af041f3ff29b4c7fe"}}}},"Results":[]}
JSON

WAIVER_FILE="$tmp/waiver.json" WAIVER_AS_OF=2026-08-12 ARTIFACTS_DIR="$artifacts" \
  "$root/scripts/verify-trivy-waivers.sh" local-grafana:test "$report" >/dev/null

cat >"$tmp/intermediate-grafana.Dockerfile" <<EOF
FROM grafana/grafana@$expected_digest AS plugin
FROM alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
if WAIVER_FILE="$tmp/waiver.json" WAIVER_AS_OF=2026-08-12 GRAFANA_DOCKERFILE="$tmp/intermediate-grafana.Dockerfile" \
  ARTIFACTS_DIR="$artifacts" "$root/scripts/verify-trivy-waivers.sh" local-grafana:test "$report" >/dev/null 2>&1; then
  echo 'trivy-waiver-test: intermediate Grafana base with malicious final base was accepted' >&2
  exit 1
fi

cat >"$tmp/forged-label.json" <<JSON
{"ArtifactName":"local-grafana:test","Metadata":{"ImageConfig":{"config":{"Labels":{"org.opencontainers.image.base.name":"grafana/grafana","org.opencontainers.image.base.digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}}},"Results":[]}
JSON
if WAIVER_FILE="$tmp/waiver.json" WAIVER_AS_OF=2026-08-12 GRAFANA_DOCKERFILE="$root/grafana/Dockerfile" \
  ARTIFACTS_DIR="$artifacts" "$root/scripts/verify-trivy-waivers.sh" local-grafana:test "$tmp/forged-label.json" >/dev/null 2>&1; then
  echo 'trivy-waiver-test: forged base label was accepted' >&2
  exit 1
fi

if WAIVER_FILE="$tmp/waiver.json" WAIVER_AS_OF=2026-08-12 ARTIFACTS_DIR="$artifacts" \
  "$root/scripts/verify-trivy-waivers.sh" attacker-grafana:test "$report" >/dev/null 2>&1; then
  echo 'trivy-waiver-test: wildcard local image was accepted' >&2
  exit 1
fi

sed 's#sha256:ab9a06d495291c7ba210426b62e9056dba6046d0945f7e9af041f3ff29b4c7fe#sha256:0000000000000000000000000000000000000000000000000000000000000000#' "$report" >"$tmp/wrong-base.json"
if WAIVER_FILE="$tmp/waiver.json" WAIVER_AS_OF=2026-08-12 ARTIFACTS_DIR="$artifacts" \
  "$root/scripts/verify-trivy-waivers.sh" local-grafana:test "$tmp/wrong-base.json" >/dev/null 2>&1; then
  echo 'trivy-waiver-test: mismatched base identity was accepted' >&2
  exit 1
fi
echo 'trivy-waiver-test: PASS (exact upstream identity and negative cases)'
