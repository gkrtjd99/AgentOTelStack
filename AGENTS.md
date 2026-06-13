# AGENTS.md — Observability stack operating guide

This repo gives any coding agent (Claude Code, Codex, OpenCode, …) a full local
observability stack and a feedback loop: **observe → reason → change code →
re-run workload → observe again.**

You (the agent) interact with telemetry through the shell scripts in `./obs`.
You do **not** need any SDK or client library — just `curl` via these wrappers.

## The loop you run

1. **Generate signal** — start the stack, then drive traffic:
   `./workload/run.sh` (synthetic load) or `cd e2e && npm test` (browser journey).
2. **Observe** — query the three signals with `./obs/*.sh` (see below).
3. **Correlate** — take a `trace_id` from a failing request and run
   `./obs/correlate.sh <trace_id>` to see its spans + every related log line.
4. **Reason & change** — edit code under `./app` (or your own service).
5. **Re-run** — `docker compose up -d --build app` to restart with your change,
   then re-run the workload and compare the metrics. Repeat.

## Architecture (what's running)

```
app (OTLP) ──> otel-collector ──fanout──> VictoriaLogs   :9428  (LogQL)
                                       ├─> VictoriaMetrics :8428  (PromQL)
                                       └─> VictoriaTraces  :10428 (Jaeger query API)
```

- The **OpenTelemetry Collector** is the single fan-out point — it receives all
  OTLP signals and replicates them to the three stores.
- **VictoriaTraces** is queried through the **Jaeger query API**, so
  `obs/traces.sh` uses Jaeger-style subcommands.

## Query tools (your interface)

All scripts default to `localhost`; override with `VL_URL`/`VM_URL`/`VT_URL`.

| Tool | Signal | Example |
|---|---|---|
| `./obs/logs.sh '<LogQL>' [limit]` | logs | `./obs/logs.sh '_time:5m severity_text:error' 50` |
| `./obs/metrics.sh '<PromQL>' [range <step>]` | metrics | `./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'` |
| `./obs/traces.sh <subcmd> ...` | traces | `./obs/traces.sh search-errors sample-app` |
| `./obs/correlate.sh <traceID>` | all three | `./obs/correlate.sh 7f3a2b...` |

Common starting queries:

```bash
# Error rate over the last minute
./obs/metrics.sh 'sum(rate(orders_processed_total{outcome="error"}[1m]))'

# p95 latency
./obs/metrics.sh 'histogram_quantile(0.95, sum by (le) (rate(order_processing_seconds_bucket[5m])))'

# Most recent error logs (each carries a trace_id)
./obs/logs.sh '_time:15m severity_text:error' 20

# Recent failing traces for the app
./obs/traces.sh search-errors sample-app

# Drill into one failing request end-to-end
./obs/correlate.sh <trace_id-from-a-log-or-trace>
```

## Making a change and verifying it

```bash
# 1. baseline
./workload/run.sh 300
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'

# 2. edit app/src/index.js (e.g. fix the flaky checkout path)

# 3. rebuild just the app and re-run
docker compose up -d --build app
./workload/run.sh 300

# 4. confirm the error rate dropped
./obs/metrics.sh 'sum(rate(orders_processed_total{outcome="error"}[1m]))'
```

## Conventions for agents

- **Always correlate before concluding.** A metric tells you *that* something is
  wrong; a trace + its logs tell you *where*. Use `correlate.sh`.
- **Logs carry `trace_id`/`span_id`** (auto-injected by OTel) — pivot on them.
- **Log level field is `severity_text`** (`info`/`warn`/`error`), not `level`.
- **Don't guess time ranges** — LogQL uses `_time:5m`/`_time:1h` filters; PromQL
  rate windows like `[1m]`/`[5m]`.
- **The app is swappable.** To observe a different service, replace `./app` (keep
  it emitting OTLP to the collector) — everything else is unchanged.
- After a fix, **leave the workload re-run output** so the next agent sees the
  before/after.

## Ports

| Service | Port | Purpose |
|---|---|---|
| sample-app | 3000 | app + UI (`http://localhost:3000`) |
| otel-collector | 4317/4318 | OTLP gRPC/HTTP ingest |
| VictoriaLogs | 9428 | LogQL query API |
| VictoriaMetrics | 8428 | PromQL query API |
| VictoriaTraces | 10428 | Jaeger query API |
