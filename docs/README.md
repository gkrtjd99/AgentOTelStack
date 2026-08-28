# Documentation index

AgentOTelStack keeps the root [`README.md`](../README.md) short. This directory
contains the detailed English authorities for installation, operation, queries,
development, and the local security boundary.

> Language switch: [한국어 index](./ko/README.md) and paired Korean translations
> are available. Do not use a translation as an operational dependency.

## Start here

| Need | Authority |
| --- | --- |
| Install a tagged, clone-independent runtime | [`AGENT_SETUP.md`](./AGENT_SETUP.md) |
| Start, stop, inspect, reset, rotate, or migrate storage | [`OPERATIONS.md`](./OPERATIONS.md) |
| Query bounded context, errors, services, and correlation | [`QUERY.md`](./QUERY.md) |
| Point an application or MCP client at the Gateway | [`CONNECT.md`](./CONNECT.md) |
| Understand the six-service topology and network boundaries | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Use the browser Dashboard or terminal overview | [`DASHBOARD.md`](./DASHBOARD.md) |
| Work from a source checkout and run tests | [`DEVELOPMENT.md`](./DEVELOPMENT.md) |
| Diagnose credentials, projects, ports, health, or no data | [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) |
| Prepare an immutable source release | [`RELEASING.md`](./RELEASING.md) |
| Replace the bundled sample application | [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md) |

## Public contracts and boundaries

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — authenticated Gateway ingest/query
  edges, Collector fan-out, internal stores, Compose profiles, networks, and
  project scope.
- [`CONNECT.md`](./CONNECT.md) — the `obs run` path, manual OTLP environment
  variables, per-language examples, and the read-only MCP adapter.
- [`DASHBOARD.md`](./DASHBOARD.md) — the sole browser UI, its one-time client
  credential, bounded routes, and Make-only browser lifecycle.
- [`SECURITY.md`](./SECURITY.md) — same-user threat model, credential roles,
  redaction, supply-chain checks, and remote-exposure warnings.
- [`JSON_CONTRACT.md`](./JSON_CONTRACT.md) — Gateway envelope and backend status
  semantics.
- [`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md) — why an
  observed response is bounded evidence rather than proof of total ingestion.

The agent contract is intentionally separate from this public manual:
[`../AGENTS.md`](../AGENTS.md) is the machine-oriented observe → reason → change
→ re-run guide, and [`../CLAUDE.md`](../CLAUDE.md) is its repository symlink.
The split-ready Dashboard module has its own build and API notes in
[`../src/dashboard/README.md`](../src/dashboard/README.md).

## Supported command boundary

Installed operations use the global `obs` launcher. Checkout-only development
uses `make` or an explicit `AGENTOTEL_DEV_MODE=1 ./bin/obs ...` prefix. Query
helpers always use the authenticated Gateway; this documentation does not
provide raw LogQL, PromQL, Jaeger, Victoria, or Collector endpoints.
