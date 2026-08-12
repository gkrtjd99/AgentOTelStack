# Architecture and public boundaries

Apps send OTLP/HTTP to the Gateway (`127.0.0.1:4318`) with the ingest bearer
token. The Gateway forwards `/v1/{traces,metrics,logs}` to the internal
collector, which fans out to VictoriaLogs (`:9428`), VictoriaMetrics (`:8428`),
and VictoriaTraces (`:10428`). Authenticated query requests use the Gateway at
`127.0.0.1:17777`; the `obs/*.sh` helpers call it. Backend ports are never
published to the host.

The core runtime has six services: `gateway`, `otel-collector`,
`otelcol-queue-init`, and the three Victoria backends. The optional-profile
`app` (sample app) makes the demo runtime seven services; it is started only by
`make demo`. `grafana` is a separate optional dashboard-profile service. The queue-init container performs
the narrow ownership setup needed by the collector's persistent queue.

Responses are versioned envelopes with backend status, `partial`, `truncated`,
freshness/scope metadata, and `content_trust`. A backend failure is visible as
partial data, never an exact answer. `project.id` and source/run state are
provenance and selection metadata, not authentication or authorization.

The Grafana profile is optional and includes the pinned VictoriaLogs datasource
plugin v0.31.0 baked into the image, alongside Metrics and Traces datasources.
The authenticated Gateway and `obs` scripts remain the authoritative agent
query interface; Victoria backend ports remain internal-only.

Troubleshooting: check `make ps`, then Gateway `/v1/health` and `/v1/version`
with the credential runner. Run `./bin/obs credentials run -- ./obs/services.sh`,
`./bin/obs credentials run -- ./obs/errors.sh <service>`, and correlate a
32-hex trace ID with `./bin/obs credentials run -- ./obs/correlate.sh <trace_id>`.
Verify the app uses `http://localhost:4318`, matching ingest credentials, and
allow for collector batching/metric export.
