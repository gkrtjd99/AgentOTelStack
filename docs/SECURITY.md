# Security boundaries

[English](./SECURITY.md) · [한국어](./ko/SECURITY.md)

AgentOTelStack is designed as a same-user local development stack. It is not a
remote multi-tenant service. A process that can read the local credential store,
control Docker, or run as the same user can read or alter the stack.

## Network and authentication

The Gateway is the only host-facing telemetry edge:

- `127.0.0.1:4318` accepts OTLP/HTTP ingest with the Gateway **ingest** bearer.
- `127.0.0.1:17777` accepts bounded query requests with the separate **query**
  bearer.
- Collector and Victoria ports stay on Docker networks and are not application
  or human connection targets.

The canonical 0600 credential JSON contains exactly `ingest_token` and
`query_token`. The Gateway rejects missing credentials and rejects equal ingest
and query tokens. `project.id` is workspace provenance and query selection, not
an authentication or authorization boundary. `--global` only removes a query
project filter; it does not make credentials or administration global.

Use `obs run` for application ingest and the credential runner for query helpers.
Do not print tokens, commit them, put them in a repository `.env`, or pass them
to an untrusted child. A legacy credential file with
`grafana_admin_password` is migration input only; normalization retains the two
Gateway tokens and never reads, exports, prints, or reuses the retired value.

## Dashboard client boundary

The Go Dashboard is the sole browser UI and is a read-only same-origin proxy to
bounded Gateway projections. Normal startup requires a separate
`DASHBOARD_CLIENT_TOKEN` of exactly 64 lowercase hexadecimal characters,
different from the Gateway query token. The supported `make dashboard` path
generates it ephemerally, passes it only to the Dashboard and readiness probe,
and prints it once in a fragment bootstrap URL.

The browser consumes the fragment in memory, scrubs it, and sends exactly one
Dashboard Authorization header on relative `/api/*` requests. The token is not
stored in cookies, Web Storage, query parameters, static assets, HTML, labels,
volumes, or logs. A full reload requires the one-time URL again. Static assets
and loopback health are intentionally public; unauthorized API requests use a
generic 401 before the Gateway is contacted.

The Dashboard never forwards the Gateway query token, ingest bearer, cookies,
Origin, or Referer. Browser input cannot select a backend URL, raw query,
telemetry write route, or arbitrary project. Host allowlisting is additional
hardening, not the client-auth boundary.

## Telemetry content and cardinality

Telemetry is untrusted content. Redact secrets and personal data before
emission, keep request bodies and credentials out of logs/spans/metric labels,
and bound label cardinality. The Gateway allowlists projected fields and strips
control characters, but it is not a general secrecy engine.

The Collector removes standalone `url.query` and `url.fragment` attributes and
cuts URL text at `?`/`#` boundaries for newly ingested data. This is not a
retroactive rewrite of records already stored in Victoria. An authorized local
sender can still create high-cardinality values or exhaust retention; use a
stricter ingest proxy/tenant policy when that threat matters.

The Dashboard image is a pinned scratch, non-root runtime with a CA bundle and
self-health probe. Active images use immutable base-image digests; CI validates
Compose build contexts, Go modules, Dockerfiles, image provenance, and secret
scans. These checks protect the build path, not a compromised same-user Docker
installation.

## Identity, reset, and legacy state

The stack UUID under
`${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid` controls active
volume labels. Setup and reset use ownership checks and reject symlinks or
mismatched projects. Use only the guarded destructive boundary:

```bash
obs reset --all --confirm
```

A `${COMPOSE_PROJECT_NAME}_grafana-data` volume from a pre-Dashboard runtime is
not active UI state. Setup, Compose, inspection, and reset do not claim,
relabel, prune, or delete it. Treat it as manual backup/migration state and
follow [`OPERATIONS.md`](./OPERATIONS.md); do not infer that its presence means
Grafana is still running.

## Remote exposure

Do not publish the Gateway, Dashboard, Collector, or Victoria ports beyond
loopback without a deliberate deployment design. If remote use is required,
place a TLS/authenticated proxy in front, restrict OTLP senders, protect and
rotate credentials, define retention and redaction policy, and keep Victoria
backend APIs private. A local bearer token and loopback binding are not a
replacement for a remote trust model.

For release integrity and checksum verification, see
[`RELEASING.md`](./RELEASING.md). For credential diagnosis, see
[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
