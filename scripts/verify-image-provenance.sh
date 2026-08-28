#!/bin/sh
# Validate image provenance policy from the resolved Compose model.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)
compose=${1:-docker-compose.yml}
case "$compose" in /*) compose_abs=$compose ;; *) compose_abs=$root/$compose ;; esac
compose_abs=$(CDPATH=; cd -- "$(dirname "$compose_abs")" && pwd)/$(basename "$compose_abs")
compose_dir=$(dirname "$compose_abs")
cd "$compose_dir"

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
AGENTOTEL_STACK_UUID=${AGENTOTEL_STACK_UUID:-00000000-0000-4000-8000-000000000001} \
AGENTOTEL_PROJECT_ID=${AGENTOTEL_PROJECT_ID:-00000000-0000-4000-8000-000000000001} \
GATEWAY_INGEST_TOKEN=${GATEWAY_INGEST_TOKEN:-ci-ingest-token} \
GATEWAY_QUERY_TOKEN=${GATEWAY_QUERY_TOKEN:-ci-query-token} \
docker compose -f "$compose_abs" --profile demo --profile dashboard config --format json >"$tmp"

python3 - "$tmp" "$compose_dir" "${AGENTOTEL_RUNTIME_VERSION:-dev}" <<'PY'
import json
import pathlib
import re
import sys

model = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2]).resolve()
runtime = sys.argv[3]
errors = []
services = model.get("services", {})
digest = re.compile(r"@sha256:[0-9a-f]{64}$", re.I)
from_re = re.compile(r"^\s*FROM(?:\s+--platform=(\S+))?\s+(\S+)(?:\s+AS\s+(\S+))?\s*$", re.I)
expected_images = {
    "app": f"dev-observability/app:{runtime}",
    "gateway": f"dev-observability/gateway:{runtime}",
    "dashboard": f"dev-observability/dashboard:{runtime}",
    "victorialogs": f"dev-observability/victorialogs:v1.52.0-health-{runtime}",
    "victoriametrics": f"dev-observability/victoriametrics:v1.150.0-health-{runtime}",
    "victoriatraces": f"dev-observability/victoriatraces:v0.11.0-health-{runtime}",
    "otel-collector": f"dev-observability/otel-collector:v0.159.0-health-{runtime}",
}
expected_builds = {
    "app": ("src/app", "Dockerfile"),
    "gateway": ("src/gateway", "Dockerfile"),
    "dashboard": ("src/dashboard", "Dockerfile"),
    "victorialogs": ("src/backend-health", "Dockerfile.victorialogs"),
    "victoriametrics": ("src/backend-health", "Dockerfile.victoriametrics"),
    "victoriatraces": ("src/backend-health", "Dockerfile.victoriatraces"),
    "otel-collector": ("src/backend-health", "Dockerfile.collector"),
}

# Every build is named. A build-only service would otherwise disappear from
# image enumeration and from the hosted Trivy gate.
for name, service in services.items():
    build = service.get("build")
    image = service.get("image")
    if build is not None and (not isinstance(image, str) or not image):
        errors.append(f"{name}: every build service must declare an explicit image")
    if build is not None and name not in expected_builds:
        errors.append(f"{name}: unexpected extra build service; canonical image mapping is required")

for retired in ("grafana", "dashboard-lite"):
    if retired in services:
        errors.append(f"{retired}: retired service remains active")

# Check each canonical service's declared identity and then count mappings by
# source and image. This catches a duplicate canonical backend hidden under a
# different service name, not just a dashboard image typo.
for name, (expected_context, expected_dockerfile) in expected_builds.items():
    service = services.get(name)
    if service is None:
        errors.append(f"{name}: canonical service is missing")
        continue
    expected_image = expected_images[name]
    if service.get("image") != expected_image:
        errors.append(f"{name}: image must be {expected_image} (got {service.get('image')})")
    build = service.get("build")
    if not isinstance(build, dict):
        errors.append(f"{name}: canonical service must have a resolved build object")
        continue
    actual_context = pathlib.Path(build.get("context", "")).resolve()
    actual_dockerfile = build.get("dockerfile", "Dockerfile")
    if actual_context != (root / expected_context).resolve() or actual_dockerfile != expected_dockerfile:
        errors.append(f"{name}: build must use {expected_context}/{expected_dockerfile} (got {actual_context}/{actual_dockerfile})")

for name, (expected_context, expected_dockerfile) in expected_builds.items():
    matches = []
    for service_name, service in services.items():
        build = service.get("build")
        if not isinstance(build, dict):
            continue
        context = pathlib.Path(build.get("context", "")).resolve()
        dockerfile = build.get("dockerfile", "Dockerfile")
        if context == (root / expected_context).resolve() and dockerfile == expected_dockerfile:
            matches.append(service_name)
    if len(matches) != 1:
        errors.append(f"{name}: canonical build mapping {expected_context}/{expected_dockerfile} must occur exactly once (found {', '.join(matches) or 'none'})")

for name, expected_image in expected_images.items():
    matches = [service_name for service_name, service in services.items() if service.get("image") == expected_image]
    if len(matches) != 1:
        errors.append(f"{name}: canonical image {expected_image} must occur exactly once (found {', '.join(matches) or 'none'})")

for name, service in services.items():
    image = service.get("image")
    build = service.get("build")
    if build is None:
        if not image or not digest.search(image):
            errors.append(f"{name}: external image must use a full @sha256 digest ({image or 'missing image'})")
        continue
    if isinstance(build, str):
        context = build
        dockerfile = "Dockerfile"
    elif isinstance(build, dict):
        context = build.get("context", ".")
        dockerfile = build.get("dockerfile", "Dockerfile")
    else:
        errors.append(f"{name}: build must be an object or path")
        continue
    df = (root / context / dockerfile).resolve()
    try:
        df.relative_to(root)
    except ValueError:
        errors.append(f"{name}: build Dockerfile escapes the Compose directory ({df})")
    if not df.is_file():
        errors.append(f"{name}: missing Dockerfile {df}")
        continue
    stages = set()
    for line_number, line in enumerate(df.read_text().splitlines(), 1):
        match = from_re.match(line)
        if not match:
            continue
        platform, base, stage = match.groups()
        if base.lower() not in stages and base.lower() != "scratch" and not digest.search(base):
            errors.append(f"{name}: {df}:{line_number}: FROM must use full @sha256 digest ({base})")
        if stage:
            stages.add(stage.lower())
    args = build.get("args", {}) if isinstance(build, dict) else {}
    if args:
        errors.append(f"{name}: mutable build args are not permitted")

# Health probes are compiled in a BuildKit stage and copied into multi-arch
# Victoria/OTel images. Require automatic target arguments and native builder
# semantics; the Dockerfile-specific check below also rejects an amd64 default.
health_dir = root / "src/backend-health"
for df in sorted(health_dir.glob("Dockerfile.*")):
    text = df.read_text()
    if not re.search(r"^ARG\s+TARGETOS\s*$", text, re.M) or not re.search(r"^ARG\s+TARGETARCH\s*$", text, re.M):
        errors.append(f"{df}: health build must declare BuildKit TARGETOS and TARGETARCH")
    if not re.search(r"^FROM\s+--platform=\$BUILDPLATFORM\s+\S+\s+AS\s+build\s*$", text, re.M):
        errors.append(f"{df}: health builder must use native BuildKit $BUILDPLATFORM")
    if re.search(r"GOARCH\s*=\s*amd64\b", text):
        errors.append(f"{df}: health build must not hard-code GOARCH=amd64")
    if not re.search(r"GOOS=\"\$\{TARGETOS:-\$\(go env GOOS\)\}\"", text) or not re.search(r"GOARCH=\"\$\{TARGETARCH:-\$\(go env GOARCH\)\}\"", text):
        errors.append(f"{df}: health build must compile for TARGETOS/TARGETARCH")

if errors:
    print("IMAGE PROVENANCE: FAIL", file=sys.stderr)
    print("\n".join(" - " + error for error in errors), file=sys.stderr)
    sys.exit(1)
print(f"IMAGE PROVENANCE: PASS ({len(services)} services; every build has a canonical image)")
PY
