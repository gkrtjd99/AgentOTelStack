# Dashboard and Overview

This stack keeps the agent-facing path script-first. The dashboard layer is
there for quick human inspection, without adding another required service to
the default stack.

## Terminal Overview

Run:

```bash
make dashboard SERVICE=sample-app
make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m
```

or directly:

```bash
./bin/obs credentials run -- ./obs/overview.sh sample-app 15m
./bin/obs credentials run -- ./obs/overview.sh --compact --lookback 15m sample-app
./bin/obs credentials run -- ./obs/overview.sh --json --since 15m sample-app
```

The overview prints:

- services seen by traces and recent logs
- metric availability for the selected service
- `orders_processed_total` by outcome, if the app emits it
- current-counter error ratio, if the app emits `orders_processed_total`
- lookback-window p95 latency, if the app emits `order_processing_seconds`
- recent error logs
- recent error traces with credential-runner `obs/correlate.sh <trace_id>` suggestions
- the authenticated Gateway query surface and optional Grafana UI

For a different local app, use its `OTEL_SERVICE_NAME`:

```bash
make dashboard SERVICE=my-app
make dashboard SERVICE=my-app MODE=compact LOOKBACK=30m
./bin/obs credentials run -- ./obs/overview.sh --json --since 30m my-app
./bin/obs credentials run -- ./obs/app.sh summary my-app
```

## Built-in UIs

These are optional inspection tools. The supported automation path remains the
authenticated credential-runner form of `./obs/*.sh`.

| Signal | URL | Notes |
|---|---|---|
| Metrics | — | Use the authenticated `obs` helpers or Grafana; VictoriaMetrics is internal |
| Logs | — | Use the authenticated `obs` helpers or Grafana's pinned VictoriaLogs plugin |
| Traces | — | Use the authenticated `obs` helpers or Grafana; VictoriaTraces is internal |

If a UI endpoint changes in a Victoria release, the script helpers are still the
source of truth because they call the query APIs directly.

## Multi-app Helpers

Use `obs/app.sh` when several apps report to the same stack:

```bash
./bin/obs credentials run -- ./obs/app.sh services
./bin/obs credentials run -- ./obs/app.sh summary my-app
./bin/obs credentials run -- ./obs/app.sh errors my-app 15m 20
./bin/obs credentials run -- ./obs/app.sh traces my-app 20 1h
./bin/obs credentials run -- ./obs/app.sh metrics my-app
```

The Gateway helpers filter by service name and hide backend-specific field
spelling and query syntax.

## Optional Grafana UI

Grafana is behind the `dashboard` compose profile, so the default `make up`
stack remains the Gateway, collector, queue initializer, and three Victoria
backends (with the sample app and Grafana profiles off).

Run:

```bash
make grafana
```

Open:

- Grafana: <http://localhost:3001>
- Provisioned dashboard: `ObservabilityStack / Local Observability`

Provisioned datasources:

| Name | Type | Backend |
|---|---|---|
| VictoriaMetrics | Prometheus-compatible | `http://victoriametrics:8428` |
| VictoriaTraces | Jaeger-compatible | `http://victoriatraces:10428/select/jaeger` |
| VictoriaLogs | `victoriametrics-logs-datasource` v0.31.0 | `http://victorialogs:9428` |

The Grafana dashboard is versioned at
[`src/dashboards/local-observability.json`](../src/dashboards/local-observability.json).
The Grafana 13.1.3 Ubuntu image is pinned by SHA-256 digest and bakes the
official VictoriaLogs datasource plugin v0.31.0 at build time with a pinned
release checksum. Plugins are loaded from immutable `/opt/grafana-plugins`,
outside the persistent `/var/lib/grafana` volume, so the data volume cannot
mask the plugin. Startup preinstall, external core-plugin management, public
key retrieval, and the plugin admin installer are disabled; the dashboard
image does not download plugins at startup. The dashboard includes request rate, HTTP p95, order metrics, recent
error logs, and links
back to the provisioned datasources plus the authenticated `obs/correlate.sh`
workflow.

Grafana is local-only and bound to `127.0.0.1:3001`. Anonymous access is off;
login requires the configured `GF_SECURITY_ADMIN_PASSWORD` (the username
defaults to `admin`). No default admin password is documented or assumed.

### Grafana Usage Examples

Start with the demo data:

```bash
make demo
./workload/run.sh 100
make grafana
```

Open <http://localhost:3001>, then select
`ObservabilityStack / Local Observability`.

Typical checks:

| Need | Grafana panel | Equivalent agent command |
|---|---|---|
| Is the app reporting? | Service variable and HTTP panels | `./bin/obs credentials run -- ./obs/app.sh services` |
| Are orders failing? | Orders By Outcome / Order Error Ratio | `./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m` |
| Is latency high? | HTTP p95 Latency / Order p95 Latency | `make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m` |
| Which requests failed? | Recent Error Logs | `./bin/obs credentials run -- ./obs/app.sh errors sample-app 15m 20` |
| What happened in one failure? | Trace Workflow links | `./bin/obs credentials run -- ./obs/correlate.sh <trace_id>` |

For your own app, set the dashboard `service` variable to its
`OTEL_SERVICE_NAME`. If business metrics such as `orders_processed_total` do
not exist, the generic HTTP panels still work as long as the app emits standard
OpenTelemetry HTTP metrics.
