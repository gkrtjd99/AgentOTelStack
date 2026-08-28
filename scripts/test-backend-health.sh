#!/usr/bin/env bash
set -euo pipefail

cd "$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo 'backend-health test requires Docker' >&2; exit 2; }
docker buildx version >/dev/null 2>&1 || { echo 'backend-health test requires Docker Buildx' >&2; exit 2; }

validation_tags=()
cleanup() {
  rc=$?
  cleanup_failed=0
  for tag in "${validation_tags[@]}"; do
    if ! docker image rm -f "$tag" >/dev/null 2>&1; then
      echo "backend-health: failed to remove exact validation image $tag" >&2
      cleanup_failed=1
    fi
  done
  if (( rc != 0 )); then return "$rc"; fi
  return "$cleanup_failed"
}
trap cleanup EXIT HUP INT TERM

for platform in linux/amd64 linux/arm64; do
  expected_arch=${platform#*/}
  for dockerfile in src/backend-health/Dockerfile.*; do
    name=$(basename "$dockerfile" | tr '[:upper:].' '[:lower:]_-')
    tag="agentotel-health-validation-${name}-${expected_arch}:local"
    validation_tags+=("$tag")
    docker buildx build --load --provenance=false --platform "$platform" \
      --file "$dockerfile" --tag "$tag" src/backend-health >/dev/null
    actual_arch=$(docker image inspect "$tag" --format '{{.Architecture}}')
    [[ "$actual_arch" == "$expected_arch" ]] || {
      echo "backend-health: $dockerfile built for $platform but image architecture is $actual_arch" >&2
      exit 1
    }
  done
done
echo 'backend-health: PASS (BuildKit linux/amd64 and linux/arm64 image architecture)'
