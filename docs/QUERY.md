# Query and correlate evidence

[English](./QUERY.md) · [한국어](./ko/QUERY.md)

Queries are authenticated, bounded projections through the Gateway query
listener at `http://127.0.0.1:17777`. The helpers deliberately hide Victoria
URLs and backend query languages. Keep the query token in the 0600 credential
store or supply an explicit controlled override; never put it in a command
example that would be copied into source control.

## Installed dispatcher

After `obs setup` and `obs up`, use the global launcher:

```bash
obs services
obs context --service my-app --lookback 15m --limit 50
obs errors --service my-app --lookback 15m --limit 20
obs correlate <32-lowercase-hex-trace-id>
```

The dispatcher also accepts a positional service for context/errors and
`--global` on each query command:

```bash
obs context --global --service my-app --lookback 1h
obs errors --global --service my-app --lookback 1h --limit 100
obs services --global
obs correlate --global <32-lowercase-hex-trace-id>
```

`obs correlate --limit` is accepted only with the helper's fixed limit of `100`
until the Gateway exposes separate per-signal caps. Normal context and errors
limits are integers from `1` through `500`.

## Checkout helpers

A source checkout should load the credential store through the explicit
credential runner:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/services.sh
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh my-app 15m 50
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/logs.sh my-app 15m 20
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/traces.sh search-errors my-app 20 1h
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/correlate.sh <32-lowercase-hex-trace-id>
```

The source helper's `--global` form must appear before its positional values,
for example:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh --global my-app 15m 50
```

For a terminal presentation, use the checkout-only overview wrapper:

```bash
make overview SERVICE=my-app MODE=compact LOOKBACK=15m
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --json --since 1h my-app
```

The overview is a presentation of the same bounded context envelope, not a
business-metric contract. It does not promise an orders ratio, p95 latency, or
an arbitrary time-series panel.

## Scope, lookback, and project

Allowed Gateway lookbacks are exactly:

- `5m`
- `15m`
- `1h`
- `6h`
- `24h`

A normal helper resolves one UUIDv4 from the current workspace's
`.agentotel/project.toml` and adds it as the `project` query parameter. This
keeps multiple local workspaces separate even when they use the same service
name. `--global` omits that filter for a deliberate cross-project diagnostic;
it does not bypass the query bearer, change ingest authentication, change the
fixed stack, or grant lifecycle/administration access.

A service name is bounded printable text without query syntax delimiters. A
trace ID is exactly 32 lowercase hexadecimal characters. The Gateway accepts
only bounded limits (`1`–`500`) and rejects unknown query parameters. A missing
or invalid workspace project is an initialization error, not evidence that the
backend has no data.

## Signals and correlation workflow

Use a staged workflow instead of drawing a root-cause conclusion from one
signal:

1. `obs context` (or `metrics.sh`) shows bounded metric and log context for a
   service and lookback.
2. `obs errors`/`logs.sh` shows recent projected error evidence. Look for a
   `trace_id`; logs may also contain `span_id` and `severity_text`.
3. `obs errors`/`traces.sh search-errors` finds recent failing trace evidence.
4. Run `obs correlate <trace_id>` (or `correlate.sh`) to request the trace,
   trace-scoped logs, and a same-service metrics snapshot.
5. Inspect the correlated operation, status, error, and backend states before
   changing code. Then rerun the same workload and compare scope and freshness.

A trace ID can be valid but not yet stored because Collector batching and
backend ingestion are asynchronous. Retry within the bounded lookback rather
than broadening into a raw backend query.

## Response states

Every Gateway query response is a JSON envelope with `schema_version` `1.0`,
`data`, `partial`, `truncated`, `content_trust: "untrusted_telemetry"`, and a
`backends` array. Backend status is evidence about the requested scope:

- `ok` — the backend query completed.
- `no_matching`, `no_matching_data`, or `trace_not_stored` — no matching evidence
  was returned in the requested scope; this is not an outage.
- `signal_not_observed` — correlation completed but one signal had no matching
  record.
- `backend_unavailable`, `backend_decode_error`, or `timeout` — operational
  failure; the envelope may be `partial`.
- `partial: true` — one or more backend signals failed, so do not treat the
  response as complete.
- `truncated: true` — a bounded response cap clipped the result; do not infer a
  total count from the returned rows.

The CLI/storage and Dashboard presentations may label an empty successful
response as `no_data`. Preserve that distinction from `partial` or
`backend_unavailable`. Telemetry content is untrusted evidence even when the
transport and backend status are `ok`.

## What is intentionally unavailable

There is no supported raw LogQL, PromQL, Jaeger, arbitrary backend URL, write
route, or browser-supplied project selector. If a needed view is not represented
by `services`, `context`, `errors`, or `correlate`, extend the bounded Gateway
contract rather than bypassing it. For browser inspection use the bounded Go
Dashboard; for agent automation use these helpers and `make overview`.
