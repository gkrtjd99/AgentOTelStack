# Dashboard Plan

The current dashboard surface is intentionally script-first:

- `make dashboard SERVICE=sample-app`
- `./obs/overview.sh <service> [lookback]`
- optional Grafana dashboard through `make grafana`
- built-in Victoria UIs documented in [`DASHBOARD.md`](./DASHBOARD.md)

This keeps the default stack small while still giving humans a quick overview.

## Goals

- Preserve the agent workflow as the primary interface: `obs/*.sh`.
- Add a human dashboard without making the core stack harder to start.
- Keep every dashboard panel backed by a command/query that agents can also run.
- Support multiple local apps through `OTEL_SERVICE_NAME`.

## Phase 1: Terminal Dashboard Hardening

Status: implemented.

Completed work:

- Add `--json` and `--compact` modes to `obs/overview.sh`.
- Show service-specific metric availability before app-specific panels.
- Add a `--since`/`--lookback` option with consistent parsing across logs and traces.
- Include top recent trace IDs with direct `obs/correlate.sh <trace_id>` suggestions.

Completion criteria:

- `make dashboard SERVICE=my-app` works even when app-specific business metrics do not exist.
- Output is short enough for humans but structured enough for agents to parse.

Validation commands:

```bash
make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m
./obs/overview.sh --json --since 15m sample-app
./obs/overview.sh --compact my-app 15m
```

## Phase 2: Optional Grafana Profile

Status: implemented.

Added an optional `dashboard` compose profile:

```bash
docker compose --profile dashboard up -d
make grafana
```

Implemented services/config:

- Grafana bound to `127.0.0.1:3001`
- Provisioned VictoriaMetrics datasource
- Provisioned VictoriaLogs datasource via `victoriametrics-logs-datasource`
- Provisioned VictoriaTraces datasource via Grafana's Jaeger datasource
- Prebuilt dashboard JSON under `dashboards/`

Initial panels:

- request/error rate by `service_name`
- p95 latency by `service_name`
- `orders_processed_total` by outcome, when present
- recent error log table
- recent error trace workflow and trace UI links

Completion criteria:

- Dashboard starts only when profile is requested.
- Core `make up` remains collector + Victoria stores only.
- Dashboard JSON is versioned and reproducible.

Validation commands:

```bash
docker compose --profile demo --profile dashboard config
make grafana
curl -fsS http://localhost:3001/api/health
curl -fsS http://localhost:3001/api/datasources
curl -fsS http://localhost:3001/api/dashboards/uid/local-observability
```

## Phase 3: Custom Local Web UI

Status: optional future work.

Only build this if Grafana is too heavy or does not fit agent workflows.

Shape:

- small static or Node UI served on `127.0.0.1:3001`
- calls the same query APIs as `obs/*.sh`
- service selector sourced from traces/logs
- detail view for one trace ID using the same logic as `obs/correlate.sh`

Completion criteria:

- No write access to telemetry stores.
- No auth claims; still documented as local-only.
- Full parity with `obs/overview.sh` before adding extra features.

## Recommended Next Dashboard Task

Phase 2 is now complete. Move to Phase 3 only if Grafana is too heavy for the
agent workflow or if a custom UI needs tighter trace/log correlation than
Grafana dashboards provide.
