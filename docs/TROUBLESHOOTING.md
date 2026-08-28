# Troubleshooting

[English](./TROUBLESHOOTING.md) · [한국어](./ko/TROUBLESHOOTING.md)

Use the installed launcher for an installed runtime and prefix checkout
commands with `AGENTOTEL_DEV_MODE=1`. Do not diagnose by connecting directly to
Collector or Victoria ports; the Gateway is the supported boundary.

## First response

Run the read-only checks below without printing credentials:

```bash
obs doctor
obs credentials status
obs project ensure
obs services
obs canary
```

For a checkout, use the equivalent explicit commands:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs doctor
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials status
AGENTOTEL_DEV_MODE=1 ./bin/obs project ensure
AGENTOTEL_DEV_MODE=1 ./bin/obs canary
```

If the stack is not running, start it with `obs up` or `make dev-up`. If the
bundled app is needed, use `make demo`; do not assume that the default core
stack includes `sample-app`.

## Docker or lifecycle failures

Check that Docker is running and that the active project is the one you meant:

```bash
obs services
obs doctor
obs storage
```

`doctor` reports Docker volume inspection failures as unavailable, warns about
low filesystem space, and reports missing stack identity, legacy volumes, or
mismatched volume ownership. The active stack owns exactly these four
persistent volumes:

- `<project>_otelcol-queue`
- `<project>_victorialogs-data`
- `<project>_victoriametrics-data`
- `<project>_victoriatraces-data`

A volume named `${COMPOSE_PROJECT_NAME}_grafana-data` is legacy state, not an
active Dashboard volume. Do not delete or relabel it as part of normal startup.
A mismatched or legacy volume requires a manual, verified backup/migration; the
stack intentionally does not migrate it automatically:

```bash
obs migrate volumes --confirm
```

The command prints the manual boundary and refuses to perform an implicit copy.
Do not use `docker compose down -v` or broad `docker volume prune` as a repair.
The guarded reset is the only supported destructive stack reset:

```bash
obs reset --all --confirm
```

It requires an interactive terminal and the current stack UUID. It removes only
owned runtime resources and preserves unrelated Docker state.

## Credentials and 401 responses

There are separate credentials for ingest and query. The canonical file is:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials
```

It is a 0600 regular file containing exactly `ingest_token` and `query_token`.
Check its status without displaying values:

```bash
obs credentials status
obs credentials ensure
```

A missing or malformed store is repaired by `ensure` only when its contents are
valid or absent. A legacy file containing `grafana_admin_password` is migration
input; status/ensure normalizes it and discards that value. It is never a
Dashboard or Gateway credential.

After rotating credentials, restart the stack so Compose injects the new pair:

```bash
obs credentials rotate
obs down
obs up
```

Use the query credential loader for reads:

```bash
obs credentials run -- ./obs/services.sh
obs credentials run -- ./obs/errors.sh sample-app 15m 20
```

A 401 from `127.0.0.1:4318` normally means the ingest bearer is missing,
malformed, or stale. A 401 from `127.0.0.1:17777` normally means the query
bearer is missing, malformed, or stale. Do not use one role in place of the
other, and do not put either token in a repository `.env` or source file.

## No services, logs, metrics, or traces

First distinguish an unavailable path from an empty projection:

```bash
obs canary
obs context --service sample-app --lookback 15m
obs errors --service sample-app --lookback 15m --limit 20
```

The canary checks authenticated Gateway health and the services projection. An
empty result can be valid `no_data`; `partial`, `backend_unavailable`,
`backend_decode_error`, and `timeout` indicate incomplete operational evidence.
Inspect every backend status and wait for Collector batching and periodic metric
export before widening the lookback.

If `sample-app` is absent, start the demo profile and check its health endpoint:

```bash
make demo
curl -fsS http://127.0.0.1:3000/health
```

For a host application, verify the process has `OTEL_SERVICE_NAME`, the Gateway
OTLP/HTTP endpoint, `http/protobuf`, the authenticated `Authorization` header,
and `agentotel.project.id`. The recommended way is:

```bash
obs run --service my-app -- <application command>
```

A service can emit logs/traces while metrics are delayed or absent. Do not
replace a missing signal with zero and do not infer root cause from a metric
label alone.

## Correlation of a failing request

Take one lowercase 32-hex trace ID from a projected error or trace, then run:

```bash
obs correlate 0123456789abcdef0123456789abcdef
```

For the checkout helper path:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- \
  ./obs/correlate.sh 0123456789abcdef0123456789abcdef
```

If correlation reports `trace_not_stored`, retry after a short delay and check
retention/lookback. If logs or metrics are absent but spans exist, report that
signal-specific limitation. `partial` or `truncated` means the response cannot
support an exact completeness claim.

## Short-lived Collector debug configuration

`src/otel-collector/config-debug.yaml` is an explicit opt-in troubleshooting
configuration. The active `docker-compose.yml` does not mount it, and normal
applications must continue to send authenticated OTLP through the Gateway. If
you temporarily run an isolated Collector for local signal diagnosis, use this
configuration only for that short-lived session: it accepts OTLP on its local
receivers and writes basic debug output rather than fan-out data to the
Victoria stores. Do not publish those receiver ports, use it as a production
configuration, or conclude that a debug export proves the Gateway write path.
Stop the temporary process and return to the normal Gateway/Collector path after
the diagnosis.

## Dashboard problems

Use the supported lifecycle first:

```bash
make dashboard
make dashboard-down
```

Open the exact one-time fragment URL printed by `make dashboard`, including the
`#token=...` fragment. The browser keeps the separate 64-lowercase-hex client
token in memory; a full reload intentionally requires the bootstrap URL again.
Static assets and `/health` are public, but `/api/*` requires:

```text
Authorization: Dashboard <64-lowercase-hex-token>
```

A Dashboard 401 is not fixed by exposing the Gateway query token to the
browser. If readiness fails, inspect the bounded service response and run:

```bash
curl -fsS http://127.0.0.1:3001/health
make ps
```

A Dashboard startup failure commonly means the client token is not exactly 64
lowercase hexadecimal characters, equals the Gateway query token, or the fixed
workspace project UUID is missing/invalid. Direct Compose startup must supply
all required server-side variables; `make dashboard` is preferred.

## Port conflicts

The default host bindings are loopback `4318` (OTLP ingest), `17777` (query),
`3000` (sample app), and `3001` (Dashboard). The Make scripts can select safe
alternate host ports; do not publish backend ports as a workaround. Check the
selected values with the Compose/Make status output and keep applications
pointed at the selected Gateway ingest port.

## Disk pressure and retention

Inspect both local filesystem pressure and bounded evidence:

```bash
obs storage
obs disk
obs cardinality sample-app
```

Logs and traces retain up to 7 days; metrics retain up to 30 days. Logs and
traces have a 2 GiB disk cap, all stores enforce 200 MiB minimum free space,
and metrics deny queries outside retention. These are upper bounds, not a
guarantee that every event remains available. High-cardinality application
attributes can exhaust storage sooner; keep IDs, request bodies, credentials,
and secrets out of metric labels and emitted telemetry.

## Installed versus checkout mismatch

An installed launcher resolves assets under the selected immutable runtime and
does not read the checkout. A checkout command must be explicit:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs ...
```

Inspect installed versions and switch back only to a known previous runtime:

```bash
obs runtime list
obs runtime rollback
```

Rollback changes runtime pointers and selects the corresponding runtime image
tags; it does not rewrite telemetry data or credentials. If an installation is
incomplete, use the release checksum and installer guidance in
[`AGENT_SETUP.md`](./AGENT_SETUP.md) and [`RELEASING.md`](./RELEASING.md).

## Escalation evidence

When reporting a problem, include the command, timestamp, selected project and
service scope, lookback/limit, exit status, and redacted output from `doctor`,
`canary`, or the relevant Gateway envelope. Include one trace ID when
correlation is involved. Never include ingest/query/client tokens or raw
credential files.
