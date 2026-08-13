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
   `./obs/correlate.sh <trace_id>` to see its spans, every related log line,
   and a same-service metrics snapshot.
4. **Reason & change** — edit code under `./app` (or your own service).
5. **Re-run** — `AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app` to restart with your change,
   then re-run the workload and compare the metrics. Repeat.

## Architecture (what's running)

```
app (OTLP) ──> Gateway :4318 ──> otel-collector ──fanout──> Victoria stores
              Gateway :17777 ──> bounded context/errors/correlate projections
```

- The **OpenTelemetry Collector** is the single fan-out point — it receives all
  OTLP signals and replicates them to the three stores.
- Query access is authenticated and projected by the Gateway. The `obs/*` tools
  never accept backend URLs or raw LogQL/PromQL/Jaeger queries.

## Query tools (your interface)

The query helpers use `GATEWAY_URL` (default `http://127.0.0.1:17777`) and
`GATEWAY_QUERY_TOKEN`. After `obs setup`, run a helper through the credential
loader so the token is read from the 0600 XDG store without printing it:
`./bin/obs credentials run -- ./obs/services.sh`. An explicitly supplied
`GATEWAY_QUERY_TOKEN` remains supported for controlled operator/test overrides.

| Tool | Signal | Example |
|---|---|---|
| `./obs/logs.sh [service] [lookback] [limit]` | projected errors/log evidence | `./bin/obs credentials run -- ./obs/logs.sh sample-app 15m 20` |
| `./obs/metrics.sh [service] [lookback]` | projected metric context | `./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m` |
| `./obs/traces.sh search-errors <service> [limit] [lookback]` | projected failing traces | `./bin/obs credentials run -- ./obs/traces.sh search-errors sample-app 20 1h` |
| `./obs/correlate.sh <32-hex-trace-id>` | bounded correlation | `./bin/obs credentials run -- ./obs/correlate.sh 7f3a2b...` |
| `./obs/app.sh <subcmd> ...` | multi-app helper | `./bin/obs credentials run -- ./obs/app.sh summary sample-app` |
| `./obs/overview.sh [--compact\|--json] [--lookback 15m] [service]` | terminal dashboard | `./bin/obs credentials run -- ./obs/overview.sh --compact sample-app` |
| `AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile dashboard up -d grafana` | browser dashboard | `http://localhost:3001` |

Common starting queries:

```bash
# Bounded metric context for a service
./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m

# Most recent projected errors (each may carry a trace_id)
./bin/obs credentials run -- ./obs/logs.sh sample-app 15m 20

# Recent failing traces for the app
./bin/obs credentials run -- ./obs/traces.sh search-errors sample-app 20 1h

# Drill into one failing request end-to-end
./bin/obs credentials run -- ./obs/correlate.sh <trace_id-from-a-log-or-trace>

# Multi-app summary / terminal dashboard
./bin/obs credentials run -- ./obs/app.sh services
./bin/obs credentials run -- ./obs/app.sh summary sample-app
./bin/obs credentials run -- ./obs/overview.sh --compact --lookback 15m sample-app
./bin/obs credentials run -- ./obs/overview.sh --json --since 15m sample-app
```

## Making a change and verifying it

```bash
# 1. baseline
./workload/run.sh 300
./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m

# 2. edit app/src/index.js (e.g. fix the flaky checkout path)

# 3. rebuild just the app and re-run
./bin/obs compose --profile demo up -d --build app
./workload/run.sh 300

# 4. confirm the error rate dropped
./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m

# Optional: run the full write/read path smoke test
./bin/obs credentials run -- ./scripts/smoke.sh
```

## Conventions for agents

- **Always correlate before concluding.** A metric tells you *that* something is
  wrong; a trace + its logs tell you *where*. Use `correlate.sh`; it also prints
  a same-service metrics snapshot for context.
- **Logs carry `trace_id`/`span_id`** (auto-injected by OTel) — pivot on them.
- **Log level field is `severity_text`** (`info`/`warn`/`error`), not `level`.
- **Don't guess time ranges** — Gateway helpers accept bounded lookbacks such as
  `5m`, `15m`, `1h`, `6h`, and `24h`; they do not accept backend query syntax.
- **The app is swappable.** To observe a different service, replace `./app` (keep
  it emitting authenticated OTLP to the Gateway) — everything else is unchanged.
- After a fix, **leave the workload re-run output** so the next agent sees the
  before/after.

## Ports

| Service | Port | Purpose |
|---|---|---|
| sample-app | 3000 | app + UI (`http://localhost:3000`) |
| Gateway | 4318 / 17777 | host-facing authenticated OTLP ingest / query |
| otel-collector | 4317/4318 | internal OTLP gRPC/HTTP fan-out only |
| VictoriaLogs / Metrics / Traces | 9428 / 8428 / 10428 | backend-only, internal network |
| Grafana | 3001 | Optional dashboard profile |
