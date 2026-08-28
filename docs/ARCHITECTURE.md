# Architecture and public boundaries

[English](./ARCHITECTURE.md) · [한국어](./ko/ARCHITECTURE.md)

AgentOTelStack has one public telemetry edge and one public query edge. Apps
write OTLP/HTTP to the Gateway; agents and humans read bounded projections from
the Gateway. The Collector and Victoria services are implementation details on
private Docker networks.

## Signal flow

```text
app -- OTLP/HTTP + ingest bearer --> Gateway :4318
                                      |
                                      +--> otel-collector --> VictoriaLogs :9428
                                      |                   --> VictoriaMetrics :8428
                                      |                   --> VictoriaTraces :10428
agent/human -- query bearer --> Gateway :17777
                                  +--> /v1/services
                                  +--> /v1/context
                                  +--> /v1/errors
                                  +--> /v1/correlate
```

The Gateway authenticates ingest and forwards the three OTLP paths to the
internal Collector. The Collector performs the single fan-out to the three
stores. Query handlers authenticate the separate query token, constrain service,
project, lookback, trace ID, and limit inputs, and project an allowlisted
response. The `obs` tools do not accept raw LogQL, PromQL, Jaeger syntax, a
backend URL, or arbitrary write data.

## Compose services and profiles

The default core has six services:

- `gateway` — host-facing authenticated ingest and query listeners
- `otel-collector` — OTLP receiver, bounded processing, and fan-out
- `otelcol-queue-init` — one-shot ownership initialization for the Collector
  queue volume
- `victorialogs` — log storage with a 7-day retention and a 2 GiB disk cap
- `victoriametrics` — metric storage with a 30-day retention
- `victoriatraces` — trace storage with a 7-day retention and a 2 GiB disk cap

The `demo` profile adds `app` (`sample-app`) on port `3000`. The `dashboard`
profile adds the Go Dashboard on port `3001`. Both profiles are opt-in; `obs
up` starts only the shared runtime. The four active persistent volumes are
`<compose-project>_otelcol-queue`, `<compose-project>_victorialogs-data`,
`<compose-project>_victoriametrics-data`, and
`<compose-project>_victoriatraces-data`.

## Networks and host ports

- `edge` carries the Gateway and the bundled app.
- `backend` is internal and carries the Collector, Gateway, and Victoria
  stores; it has no host port.
- `dashboard` is shared only by the Gateway and Dashboard so the Dashboard can
  proxy query requests without placing the app or stores on that network.
- The Gateway publishes `127.0.0.1:4318` for OTLP ingest and
  `127.0.0.1:17777` for query. The app and Dashboard publish loopback ports
  `3000` and `3001` respectively when their profiles are enabled.

The standalone Dashboard binary defaults to `127.0.0.1:3000`; Compose sets its
container listener to `:3000` and owns the host loopback binding. Victoria
ports and the Collector's gRPC/HTTP listeners remain Docker-internal.

## Project scope and response projection

`.agentotel/project.toml` supplies a UUIDv4 workspace project identity. Normal
query helpers append that project to every request. The identity is provenance
and selection metadata, not authentication. `--global` is an explicit query
scope override only; the query bearer, Gateway boundary, and stack lifecycle
remain required.

Gateway responses use the versioned envelope described in
[`JSON_CONTRACT.md`](./JSON_CONTRACT.md). Backend failures are represented in
`backends` and may set `partial`; an empty result or a trace that is not stored
is evidence of absence within the requested scope, not proof that ingestion
failed. Telemetry is untrusted content and is projected with bounded fields.

## Dashboard boundary

The Go Dashboard is the sole browser UI. It is a stateless, same-origin server-
side adapter for the bounded services/context/errors/correlate views. Its
separate 64-lowercase-hex client token is delivered by the one-time fragment
URL; the Gateway query token and fixed workspace project stay server-side. It
has no raw backend query route, telemetry write route, arbitrary project
selector, or Victoria host port. The terminal `overview` command and the
`obs/*.sh` helpers remain the agent-facing interface.

## Legacy Grafana state

A volume named `${COMPOSE_PROJECT_NAME}_grafana-data` may remain from an older
runtime. It is not declared by active Compose, setup, volume inspection, or
reset contracts. The runtime never claims, relabels, resets, prunes, or
auto-deletes it. Treat it only as manual migration or backup state; the
procedure belongs to [`OPERATIONS.md`](./OPERATIONS.md).

For lifecycle commands, storage retention, and project/volume checks, see
[`OPERATIONS.md`](./OPERATIONS.md). For app configuration, see
[`CONNECT.md`](./CONNECT.md).
