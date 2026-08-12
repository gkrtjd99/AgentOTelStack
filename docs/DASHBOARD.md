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
./obs/overview.sh sample-app 15m
./obs/overview.sh --compact --lookback 15m sample-app
./obs/overview.sh --json --since 15m sample-app
```

The overview prints:

- services seen by traces and recent logs
- metric availability for the selected service
- `orders_processed_total` by outcome, if the app emits it
- current-counter error ratio, if the app emits `orders_processed_total`
- lookback-window p95 latency, if the app emits `order_processing_seconds`
- recent error logs
- recent error traces with `obs/correlate.sh <trace_id>` suggestions
- built-in Victoria UI URLs

For a different local app, use its `OTEL_SERVICE_NAME`:

```bash
make dashboard SERVICE=my-app
make dashboard SERVICE=my-app MODE=compact LOOKBACK=30m
./obs/overview.sh --json --since 30m my-app
./obs/app.sh summary my-app
```

## Built-in UIs

These are optional inspection tools. The supported automation path remains
`./obs/*.sh`.

| Signal | URL | Notes |
|---|---|---|
| Metrics | <http://localhost:8428/vmui/> | VictoriaMetrics MetricsQL/PromQL UI |
| Logs | — | Use `./obs/logs.sh` or the Gateway API; VictoriaLogs is internal |
| Traces | — | Use `./obs/traces.sh` or the Gateway API; VictoriaTraces is internal |

If a UI endpoint changes in a Victoria release, the script helpers are still the
source of truth because they call the query APIs directly.

## Multi-app Helpers

Use `obs/app.sh` when several apps report to the same stack:

```bash
./obs/app.sh services
./obs/app.sh summary my-app
./obs/app.sh errors my-app 15m 20
./obs/app.sh traces my-app 20 1h
./obs/app.sh metrics my-app
```

Logs filter by `service.name`, metrics by `service_name`, and traces by Jaeger
service. The helper hides that backend-specific spelling.

## Optional Grafana UI

Grafana is behind the `dashboard` compose profile, so the default `make up`
stack remains the seven-service runtime (with the sample app profile off).

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
[`dashboards/local-observability.json`](../dashboards/local-observability.json).
The Grafana 13.1.3 Ubuntu image is pinned by SHA-256 digest and bakes the
official VictoriaLogs datasource plugin v0.31.0 at build time with a pinned
release checksum. Plugins are loaded from immutable `/opt/grafana-plugins`,
outside the persistent `/var/lib/grafana` volume, so the data volume cannot
mask the plugin. Startup preinstall, external core-plugin management, public
key retrieval, and the plugin admin installer are disabled; the dashboard
image does not download plugins at startup. The dashboard includes request rate, HTTP p95, order metrics, recent
error logs, and links
back to the Victoria UIs plus the `obs/correlate.sh` workflow.

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
| Is the app reporting? | Service variable and HTTP panels | `./obs/app.sh services` |
| Are orders failing? | Orders By Outcome / Order Error Ratio | `./obs/metrics.sh 'sum by (outcome) (orders_processed_total{service_name="sample-app"})'` |
| Is latency high? | HTTP p95 Latency / Order p95 Latency | `make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m` |
| Which requests failed? | Recent Error Logs | `./obs/app.sh errors sample-app 15m 20` |
| What happened in one failure? | Trace Workflow links | `./obs/correlate.sh <trace_id>` |

For your own app, set the dashboard `service` variable to its
`OTEL_SERVICE_NAME`. If business metrics such as `orders_processed_total` do
not exist, the generic HTTP panels still work as long as the app emits standard
OpenTelemetry HTTP metrics.
