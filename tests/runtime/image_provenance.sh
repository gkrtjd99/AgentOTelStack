#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM

run_verifier() {
  AGENTOTEL_RUNTIME_VERSION=dev \
  AGENTOTEL_STACK_UUID=00000000-0000-4000-8000-000000000001 \
  AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
  GATEWAY_INGEST_TOKEN=ci-ingest-token \
  GATEWAY_QUERY_TOKEN=ci-query-token \
  "$root/scripts/verify-image-provenance.sh" "$1"
}

run_verifier "$root/docker-compose.yml" >/dev/null

for fixture in \
  "$root/tests/fixtures/image-provenance/negative-external.yml" \
  "$root/tests/fixtures/image-provenance/negative-missing.yml" \
  "$root/tests/fixtures/image-provenance/negative-unpinned.yml"; do
  if run_verifier "$fixture" >/dev/null 2>&1; then
    echo "image provenance accepted negative fixture: $fixture" >&2
    exit 1
  fi
done

# Keep temporary Compose files rooted at a symlinked source tree so the verifier
# can compare resolved contexts without copying build inputs.
canonical="$t/canonical"
mkdir -p "$canonical"
ln -s "$root/src" "$canonical/src"
cp "$root/docker-compose.yml" "$canonical/docker-compose.yml"

wrong_context="$t/wrong-context.yml"
sed 's#build: ./src/dashboard#build: ./src/gateway#' "$canonical/docker-compose.yml" > "$wrong_context"
if run_verifier "$wrong_context" >/dev/null 2>&1; then
  echo 'image provenance accepted a dashboard build from the wrong context' >&2
  exit 1
fi

# Every health/collector service gets an independently generated wrong-Dockerfile
# and wrong-image fixture. These are intentionally resolved Compose models, so
# the verifier must reject both context mapping mistakes and image identity
# swaps rather than merely checking that a Dockerfile exists.
for service in victorialogs victoriametrics victoriatraces otel-collector; do
  case "$service" in
    victorialogs) wrong_df=Dockerfile.victoriametrics; wrong_image='dev-observability/victoriametrics:v1.150.0-health-dev' ;;
    victoriametrics) wrong_df=Dockerfile.victoriatraces; wrong_image='dev-observability/victoriatraces:v0.11.0-health-dev' ;;
    victoriatraces) wrong_df=Dockerfile.collector; wrong_image='dev-observability/otel-collector:v0.159.0-health-dev' ;;
    otel-collector) wrong_df=Dockerfile.victorialogs; wrong_image='dev-observability/victorialogs:v1.52.0-health-dev' ;;
  esac
  wrong_df_fixture="$t/wrong-$service-dockerfile.yml"
  wrong_image_fixture="$t/wrong-$service-image.yml"
  python3 - "$canonical/docker-compose.yml" "$wrong_df_fixture" "$wrong_image_fixture" "$service" "$wrong_df" "$wrong_image" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
df_out, image_out, service, wrong_df, wrong_image = sys.argv[2:]
block_re = re.compile(rf'(?ms)^  {re.escape(service)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|^volumes:\n)')
match = block_re.search(source)
if not match:
    raise SystemExit(f'missing service block: {service}')
block = match.group(0)
wrong_block = re.sub(r'(?m)^    build: \{context: ./src/backend-health, dockerfile: [^}]+\}',
                     f'    build: {{context: ./src/backend-health, dockerfile: {wrong_df}}}', block, count=1)
if wrong_block == block:
    raise SystemExit(f'missing health build line: {service}')
pathlib.Path(df_out).write_text(source[:match.start()] + wrong_block + source[match.end():])
wrong_block = re.sub(r'(?m)^    image: .*$', f'    image: {wrong_image}', block, count=1)
if wrong_block == block:
    raise SystemExit(f'missing service image line: {service}')
pathlib.Path(image_out).write_text(source[:match.start()] + wrong_block + source[match.end():])
PY
  if run_verifier "$wrong_df_fixture" >/dev/null 2>&1; then
    echo "image provenance accepted wrong Dockerfile fixture for $service" >&2
    exit 1
  fi
  if run_verifier "$wrong_image_fixture" >/dev/null 2>&1; then
    echo "image provenance accepted wrong image fixture for $service" >&2
    exit 1
  fi
done

duplicate="$t/duplicate-dashboard.yml"
# This literal is intentionally rewritten in a temporary Compose fixture.
# shellcheck disable=SC2016
sed 's#dev-observability/gateway:${AGENTOTEL_RUNTIME_VERSION:-dev}#dev-observability/dashboard:${AGENTOTEL_RUNTIME_VERSION:-dev}#' \
  "$canonical/docker-compose.yml" > "$duplicate"
if run_verifier "$duplicate" >/dev/null 2>&1; then
  echo 'image provenance accepted a duplicate dashboard image' >&2
  exit 1
fi

retired="$t/retired.yml"
python3 - "$canonical/docker-compose.yml" "$retired" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
retired = '''  grafana:
    image: alpine:3.22@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
'''
needle = "\nvolumes:\n"
if needle not in source:
    raise SystemExit("Compose volumes section missing")
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, "\n" + retired + needle, 1))
PY
if run_verifier "$retired" >/dev/null 2>&1; then
  echo 'image provenance accepted a retired dashboard service' >&2
  exit 1
fi

echo 'image provenance contract: PASS (canonical contexts, digest policy, and negative fixtures)'
