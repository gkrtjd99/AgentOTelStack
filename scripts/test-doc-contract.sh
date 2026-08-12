#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail(){ echo "doc-contract: $*" >&2; exit 1; }

grep -Fq "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20\${GATEWAY_INGEST_TOKEN}" .env.example \
  || fail '.env.example must show the Gateway bearer header'
! grep -Fq 'http://otel-collector:4318' .env.example \
  || fail '.env.example must not direct apps to the collector'
grep -Fq 'authenticated OTLP to the Gateway' AGENTS.md \
  || fail 'AGENTS.md must describe the Gateway write path'
! grep -Fq 'it emitting OTLP to the collector' AGENTS.md \
  || fail 'AGENTS.md contains a stale direct-collector claim'
grep -Fq 'authenticated Gateway' README.md \
  || fail 'README.md must identify the authenticated Gateway'
! grep -Fq '앱은 컬렉터로 텔레메트리를 쓰고' README.md \
  || fail 'README.md contains a stale Korean direct-collector claim'
grep -Fq 'scoped to the project in the MCP workspace' docs/CONNECT.md \
  || fail 'CONNECT.md must document workspace project scope'
grep -Fq 'scoped to the project resolved from its workspace' docs/SECURITY.md \
  || fail 'SECURITY.md must document MCP project scope'
grep -Fq 'do not accept an arbitrary project argument' docs/AGENT_SETUP.md \
  || fail 'AGENT_SETUP.md must document fixed MCP project scope'

# Installed operational lifecycle commands must come from the global launcher.
# Keep checkout-only Makefile aliases out of operator-facing setup/lifecycle
# guidance; development instructions should use explicit dev targets or the
# AGENTOTEL_DEV_MODE wrapper instead.
for doc in README.md AGENTS.md docs/AGENT_SETUP.md docs/CONNECT.md; do
  ! grep -Eq 'make (setup|up|down|clean|doctor|storage|migrate|reset|demo|smoke|dashboard|grafana|ps)([[:space:]]|$)' "$doc" \
    || fail "$doc contains stale operational make lifecycle guidance"
  ! grep -Eq '\./bin/obs (setup|up|down|doctor)([[:space:]]|$)' "$doc" \
    || fail "$doc uses checkout launcher for installed lifecycle"
done
grep -Fq 'obs setup' README.md || fail 'README.md must show global obs setup'
grep -Fq 'obs up' README.md || fail 'README.md must show global obs up'
grep -Fq 'obs down' README.md || fail 'README.md must show global obs down'
grep -Fq 'obs doctor' README.md || fail 'README.md must show global obs doctor'
grep -Fq 'obs setup' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs setup'
grep -Fq 'obs up' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs up'
grep -Fq 'obs down' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs down'
grep -Fq 'obs doctor' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs doctor'

echo 'doc-contract: PASS (Gateway-only app examples and workspace-scoped MCP docs)'
