# Development from a source checkout

[English](./DEVELOPMENT.md) · [한국어](./ko/DEVELOPMENT.md)

A checkout is a development input, not an installed runtime. The launcher does
not silently prefer checkout files: use a checkout-only Make target or the
explicit `AGENTOTEL_DEV_MODE=1` prefix.

## Prepare and run the checkout

On a fresh checkout:

```bash
make dev-setup
make demo
```

`make dev-setup` resolves the checkout workspace project, initializes the
credential store, and creates the labeled volumes for the Make-owned Compose
project. `make demo` starts the shared core and the bundled `sample-app` on
loopback port `3000`. For infrastructure only, use `make dev-up`; stop with
`make dev-down` or `make clean` (both preserve telemetry volumes).

Equivalent explicit source commands are useful when a target is not available:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app
AGENTOTEL_DEV_MODE=1 ./bin/obs doctor
```

Do not use a bare `./bin/obs` as a source-development claim. Installed
operations use `obs setup`, `obs up`, and the other global commands described in
[`AGENT_SETUP.md`](./AGENT_SETUP.md) and [`OPERATIONS.md`](./OPERATIONS.md).

## Make targets

Run `make help` to see the current list. Important checkout-only targets are:

- `make dev-setup`, `make dev-up`, `make demo`, `make dev-down` — setup and
  Compose lifecycle
- `make load N=500` — synthetic workload
- `make smoke N=120` — authenticated read-path smoke (read-only by default); for intentional workload generation, run `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./scripts/smoke.sh --write 120`
- `make doctor`, `make storage`, `make overview SERVICE=...` — read-only checks
- `make dashboard`, `make dashboard-down` — optional Go Dashboard lifecycle
- `make e2e`, `make e2e-app`, `make e2e-dashboard` — Make-managed browser journeys
- `make ci-local` — strict local CI/release inventory

`make e2e-dashboard` selects only the Dashboard spec but starts both `demo` and
`dashboard` profiles because the journey requires live sample-app errors and a
correlatable trace. Direct `cd e2e && npm test` is unsupported; it can run
against stale services and bypass the project/readiness/cleanup contract.

## Code layout

- `src/app/` — bundled Node sample service and its OTel bootstrap; swappable
  under the contract in [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md)
- `src/gateway/` — authenticated OTLP/query Gateway and versioned schemas
- `src/otel-collector/` — redaction, bounded shaping, and fan-out config
- `src/dashboard/` — split-ready standard-library Go browser module
- `src/mcp/` — read-only stdio adapter
- `obs/` — bounded query helpers
- `libexec/agentotel/` — launcher, credentials, project, lifecycle, and query
  dispatchers
- `workload/` and `e2e/` — synthetic traffic and Make-managed browser journeys

`.agentotel/project.toml` is local identity metadata and is intentionally not a
shared source artifact. Preserve it separately when replacing a checkout if
its project scope must survive.

## Focused tests

Run tests in the module you changed. Examples:

```bash
# Bundled app
(cd src/app && npm ci && npm test)

# Gateway (the CI image is the portable path when Go is unavailable)
(cd src/gateway && go test ./... && go test -race ./... && go build ./...)

# Dashboard
(cd src/dashboard && go test ./... && go test -race ./... && go vet ./... && go build ./...)
```

The repository CI uses pinned Docker images for toolchain portability and also
checks formatting, shell syntax, image provenance, security, identity, and
runtime contracts. For a strict local inventory use:

```bash
./scripts/test-ci-local.sh
```

Run the Make browser targets rather than invoking Playwright directly. Do not
run a broad Docker cleanup merely because Markdown or a small source file
changed; use the lifecycle owned by the target you are testing. Hosted live
integration must set `RUN_DASHBOARD_E2E=1`; without it the integration command
fails instead of claiming backend-only success as complete browser evidence.

## Observe a code change

The recommended feedback loop is:

```bash
./workload/run.sh 300
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m
# edit the application
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app
./workload/run.sh 300
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m
```

Always correlate a concrete error trace before deciding what to change. Leave
before/after command output in the agent report or task context.
