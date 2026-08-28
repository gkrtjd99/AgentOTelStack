# AgentOTelStack agent contract

This repository gives an agent a local observability feedback loop:
**observe → reason → change code → re-run the workload → observe again**.
`CLAUDE.md` is a symlink to this file; keep that relationship intact when
editing the agent contract.

## The required loop

1. **Generate signal.** Start the checkout demo when needed, then use
   `./workload/run.sh` or a supported Make browser journey. Browser E2E is
   Make-only: use `make e2e`, `make e2e-app`, or `make e2e-dashboard`. Direct
   `cd e2e && npm test` is unsupported and must be rejected.
2. **Observe.** Use the authenticated bounded helpers through the credential
   loader. Do not call Victoria, Collector, or raw backend query APIs directly.
3. **Correlate before concluding.** Select a 32-lowercase-hex `trace_id` from a
   failing error/log/trace result and run `correlate.sh`. A metric shows that a
   problem exists; the correlated spans and logs show where the request failed.
4. **Reason and change.** Change the application under observation, normally
   `src/app` or the explicitly supplied service. Keep credentials and raw
   telemetry out of source and logs.
5. **Re-run and compare.** Rebuild only the changed checkout service, repeat the
   workload, and leave the before/after evidence visible for the next agent.

For a checkout change, the focused restart is:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app
./workload/run.sh 300
```

## Runtime boundary

```text
app or your service -- authenticated OTLP/HTTP :4318 --> Gateway
agent or human       -- authenticated bounded queries :17777 --> Gateway
Gateway --> OpenTelemetry Collector --> Victoria Logs/Metrics/Traces
```

The Gateway is the only host-facing telemetry edge. The Collector is the
single fan-out point and is an internal app destination. Query access is
authenticated and projected by the Gateway; the helpers never accept raw
LogQL, PromQL, Jaeger queries, backend URLs, or arbitrary project selectors.

The default core is six Compose services: `gateway`, `otel-collector`, the
one-shot `otelcol-queue-init`, and the three Victoria stores. The `demo` profile
adds `app`; the `dashboard` profile adds the Go Dashboard. The Go Dashboard is
the sole browser UI, uses a dedicated network shared with Gateway, has a
standalone default of loopback `127.0.0.1:3000`, and is published by Compose on
loopback `127.0.0.1:3001`. It is not the agent automation path: use these
scripts and the terminal `overview` command.

## Query tools

Installed operation commands use `obs`. From a source checkout, use
`AGENTOTEL_DEV_MODE=1 ./bin/obs ...` or run a helper through the credential
loader so the 0600 XDG store is read without printing a token.

| Purpose | Installed command | Checkout helper |
| --- | --- | --- |
| List services | `obs services` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/services.sh` |
| Bounded context | `obs context --service sample-app --lookback 15m` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh sample-app 15m 50` |
| Recent errors | `obs errors --service sample-app --lookback 15m --limit 20` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/logs.sh sample-app 15m 20` |
| Error evidence (logs + traces) | `obs errors --service sample-app --lookback 1h --limit 20` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/traces.sh search-errors sample-app 20 1h` |
| Correlate one request | `obs correlate <trace-id>` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/correlate.sh <trace-id>` |
| Terminal overview | `make overview SERVICE=sample-app` | `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --compact --lookback 15m sample-app` |

Gateway lookbacks are exactly `5m`, `15m`, `1h`, `6h`, and `24h`; helper limits
are bounded. A query normally carries the workspace project from
`.agentotel/project.toml`. `--global` removes only that query filter. It does
not bypass authentication, ingest scope, lifecycle guards, or stack
administration. Read [`docs/QUERY.md`](./docs/QUERY.md) for response states and
the complete correlation workflow.

## Agent invariants

- Logs use `severity_text` (`info`, `warn`, or `error`), not a guessed `level`
  field. Logs and spans carry `trace_id`/`span_id` when instrumentation emits
  them.
- Do not guess a time range or invent a zero for missing data. Preserve
  `no_matching_data`, `partial`, `truncated`, and backend-unavailable states.
- Always use the Gateway's authenticated query path. Never expose
  `GATEWAY_INGEST_TOKEN`, `GATEWAY_QUERY_TOKEN`, or Dashboard credentials in
  output.
- `agentotel.project.id` is workspace provenance and query scope, not
  authentication. Keep the project metadata local and preserve it when
  replacing a checkout.
- `src/app` is swappable, but the bundled workload and browser journeys depend
  on its documented HTTP and telemetry contract. See
  [`docs/REPLACE_SAMPLE_APP.md`](./docs/REPLACE_SAMPLE_APP.md).
- After a fix, leave the workload re-run output and state what changed in the
  comparison.

## Ports

| Service | Port | Boundary |
| --- | --- | --- |
| Gateway ingest | `127.0.0.1:4318` | Authenticated OTLP/HTTP |
| Gateway query | `127.0.0.1:17777` | Authenticated bounded projections |
| sample app | `127.0.0.1:3000` | `demo` profile only |
| Dashboard | `127.0.0.1:3001` | `dashboard` profile, loopback only |
| Collector and Victoria stores | Docker-internal | Never an app/query target |

## Public references

- [`docs/README.md`](./docs/README.md) — English authority index
- [`docs/OPERATIONS.md`](./docs/OPERATIONS.md) — lifecycle and storage
- [`docs/QUERY.md`](./docs/QUERY.md) — bounded evidence queries
- [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) — checkout workflow and tests
- [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) — diagnosis
- [`docs/SECURITY.md`](./docs/SECURITY.md) — security boundaries
