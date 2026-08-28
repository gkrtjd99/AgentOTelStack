#!/bin/sh
# Verify the Go dashboard is the sole browser service and stays on the app edge.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo 'compose network contract requires docker' >&2
  exit 2
fi
token_half=$(printf '%s' 01234567 89abcdef)
dashboard_token=$(printf '%s' "$token_half" "$token_half" "$token_half" "$token_half")
AGENTOTEL_PROJECT_ID=00000000-0000-4000-8000-000000000002 \
GATEWAY_INGEST_TOKEN=ci-ingest-token \
GATEWAY_QUERY_TOKEN=ci-query-token \
DASHBOARD_CLIENT_TOKEN="$dashboard_token" \
DASHBOARD_HOST_PORT=3001 \
docker compose -f "$root/docker-compose.yml" \
  --profile demo --profile dashboard config --format json >"$tmp"

python3 - "$tmp" <<'PY'
import json
import re
import sys

model = json.load(open(sys.argv[1]))
networks = model.get("networks", {})
services = model.get("services", {})
volumes = model.get("volumes", {})
errors = []

def names(service):
    return set(services.get(service, {}).get("networks", {}))

if networks.get("backend", {}).get("internal") is not True:
    errors.append("backend must remain internal")
if "dashboard" not in services:
    errors.append("dashboard service is missing")
else:
    dashboard = services["dashboard"]
    if dashboard.get("profiles") != ["dashboard"]:
        errors.append(f"dashboard profiles are {dashboard.get('profiles')!r}")
    if dashboard.get("image") != "dev-observability/dashboard:dev":
        errors.append(f"dashboard image is {dashboard.get('image')!r}")
    if names("dashboard") != {"dashboard"}:
        errors.append(f"dashboard networks are {sorted(names('dashboard'))}, want dedicated dashboard only")
    if networks.get("dashboard", {}).get("internal") is True:
        errors.append("dashboard network must remain host-reachable for Docker Desktop publication")
    ports = dashboard.get("ports", [])
    if len(ports) != 1 or ports[0].get("host_ip") != "127.0.0.1" or str(ports[0].get("published")) != "3001" or ports[0].get("target") != 3000:
        errors.append(f"dashboard port is {ports!r}, want loopback 3001:3000")
    env = dashboard.get("environment", {})
    gateway_env = services.get("gateway", {}).get("environment", {})
    if env.get("DASHBOARD_GATEWAY_URL") != "http://gateway:17777":
        errors.append("dashboard gateway URL is not Docker-internal")
    if env.get("DASHBOARD_PROJECT_ID") != "00000000-0000-4000-8000-000000000002":
        errors.append("dashboard project is not fixed to the workspace project")
    if env.get("DASHBOARD_QUERY_TOKEN") != gateway_env.get("GATEWAY_QUERY_TOKEN"):
        errors.append("dashboard and Gateway query tokens differ")
    client_token = env.get("DASHBOARD_CLIENT_TOKEN")
    if not isinstance(client_token, str) or not re.fullmatch(r"[0-9a-f]{64}", client_token):
        errors.append("dashboard client token is not a valid 64-hex fixture")
    if client_token == env.get("DASHBOARD_QUERY_TOKEN"):
        errors.append("dashboard client and query tokens must differ")
    if env.get("DASHBOARD_LISTEN_ADDR") != ":3000":
        errors.append("dashboard listen address must be :3000")
    health = dashboard.get("healthcheck", {}).get("test")
    if health != ["CMD", "/dashboard", "healthcheck"]:
        errors.append(f"dashboard healthcheck is {health!r}, want exec healthcheck")

if names("app") != {"edge"}:
    errors.append(f"app networks are {sorted(names('app'))}, app must remain edge-only")
if names("gateway") != {"edge", "backend", "dashboard"}:
    errors.append(f"gateway networks are {sorted(names('gateway'))}, want edge/backend/dashboard")
if services.get("otelcol-queue-init", {}).get("network_mode") != "none":
    errors.append("queue init must use network_mode none")

for retired in ("grafana", "dashboard-lite"):
    if retired in services:
        errors.append(f"retired service remains active: {retired}")
for retired in ("grafana-edge",):
    if retired in networks:
        errors.append(f"retired network remains active: {retired}")
if any("grafana" in name for name in volumes):
    errors.append("retired Grafana volume remains in active Compose volumes")
for service in ("victorialogs", "victoriametrics", "victoriatraces", "otel-collector"):
    if names(service) != {"backend"}:
        errors.append(f"{service} networks are {sorted(names(service))}, want backend only")
for service in ("victorialogs", "victoriametrics", "victoriatraces"):
    if services.get(service, {}).get("ports"):
        errors.append(f"{service} publishes a backend port")
for collection, retired in ((services, ("grafana", "dashboard-lite")),
                           (networks, ("grafana", "grafana-edge", "dashboard-lite")),
                           (volumes, ("grafana-data", "dashboard-lite"))):
    for name in collection:
        if any(token in name.lower() for token in retired):
            errors.append(f"retired Compose resource remains active: {name}")

if errors:
    raise SystemExit("compose network contract: FAIL\n - " + "\n - ".join(errors))
print("compose network contract: PASS (dashboard dedicated loopback-published network; app edge-only; backend remains internal)")
PY
