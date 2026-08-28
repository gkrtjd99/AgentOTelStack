# Agent Observability Dashboard

This directory is a self-contained, split-ready browser dashboard module. It is
kept in this repository today; no separate repository is assumed or required.
The module builds one stateless Go binary with only the standard library and
embedded HTML, CSS, and JavaScript assets.

The Dashboard is the repository's sole browser UI. The authenticated, bounded
`obs` helpers and terminal `overview` remain the authoritative agent interface.
For the user-facing operating guide, see [`../../docs/DASHBOARD.md`](../../docs/DASHBOARD.md);
for the threat model, see [`../../docs/SECURITY.md`](../../docs/SECURITY.md).

## Build and run locally

From this directory, with a Go toolchain:

```bash
go test ./...
go build -trimpath -ldflags='-s -w' -o /tmp/agentotel-dashboard ./cmd/dashboard
DASHBOARD_GATEWAY_URL=http://127.0.0.1:17777 \
DASHBOARD_QUERY_TOKEN=<gateway-query-token> \
DASHBOARD_CLIENT_TOKEN=<64-lowercase-hex-token> \
DASHBOARD_PROJECT_ID=550e8400-e29b-41d4-a716-446655440000 \
  /tmp/agentotel-dashboard
```

The standalone binary listens on `127.0.0.1:3000` by default. The Compose
profile listens inside the container on `:3000` and publishes loopback
`http://127.0.0.1:3001` by default. From the repository root, the supported
checkout lifecycle owns token generation, project/credential injection,
readiness, and the one-time URL:

```bash
make dashboard
# open the exact `dashboard bootstrap URL: .../#token=...` line
make dashboard-down
```

For direct source Compose startup, provide a valid distinct token yourself:

```bash
export DASHBOARD_CLIENT_TOKEN=<64-lowercase-hex-token>
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile dashboard up -d --build dashboard
# open http://127.0.0.1:3001/#token=$DASHBOARD_CLIENT_TOKEN
```

The binary has no token endpoint. A normal start requires a client token of
exactly 64 lowercase hexadecimal characters, different from the Gateway query
token. The browser consumes the fragment in memory, scrubs it, and sends the
token only as a Dashboard Authorization header; it is not stored in cookies,
Web Storage, query parameters, HTML, static assets, or logs. A full reload
requires the bootstrap URL again. The `healthcheck` subcommand intentionally
omits client-token validation so a container can probe local readiness.

## Configuration

All configuration is read at startup. The browser cannot choose the Gateway
target or project. The Compose path injects the query credential and fixed
workspace project server-side.

| Variable | Default | Meaning |
| --- | --- | --- |
| `DASHBOARD_GATEWAY_URL` | `http://gateway:17777` | Gateway query listener; `http`/`https` URL with a host and no path, query, fragment, or user info. |
| `DASHBOARD_QUERY_TOKEN` | none | Server-side Gateway query credential; required for normal startup. |
| `DASHBOARD_CLIENT_TOKEN` | none | Separate browser credential; exactly 64 lowercase hex characters and not equal to the query token. |
| `DASHBOARD_PROJECT_ID` | none | Fixed workspace UUIDv4; required for normal startup. |
| `DASHBOARD_LISTEN_ADDR` | `127.0.0.1:3000` | Local listen address; Compose overrides it to `:3000`. |

Values containing NUL, CR, or LF are rejected where applicable. Do not put
these values in source control or expose the Gateway query credential to the
browser.

## Bounded API

The server is a same-origin read adapter. Every `/api/*` request requires
exactly one:

```text
Authorization: Dashboard <64-lowercase-hex-token>
```

| Route | Method | Accepted input |
| --- | --- | --- |
| `/api/services` | `GET` | No query parameters. |
| `/api/context` | `GET` | `service`, `lookback` (`5m`, `15m`, `1h`, `6h`, `24h`), and `limit` (`1`–`500`). |
| `/api/errors` | `GET` | Same bounded parameters; Gateway applies the error projection. |
| `/api/correlate` | `POST` | Strict JSON with lowercase 32-hex `trace_id` and optional `limit` (`1`–`500`). |
| `/health` | `GET` | Loopback callers only; no query string. |
| `/` and `/assets/*` | `GET`, `HEAD` | Embedded, validated assets. |

Unknown or duplicate query/JSON fields, malformed trace IDs, invalid service
names, unsupported lookbacks, out-of-range limits, and browser project fields
are rejected before an upstream request. The proxy supplies only the fixed
project and server-side Gateway query credential. It exposes no raw LogQL,
PromQL, Jaeger query, arbitrary backend URL, CORS proxy, telemetry write route,
or browser project selector. Returned telemetry is untrusted evidence and
preserves partial, truncated, no-data, and backend status states.

## Runtime and security properties

- The module imports only the Go standard library and embeds its static assets
  with `go:embed`.
- Upstream redirects are not followed; request/response sizes are bounded;
  correlation bodies are capped at 64 KiB and upstream responses at 1 MiB.
- Browser credentials and proxy headers are not forwarded upstream. The query
  token is never copied into a response.
- The service is stateless: no telemetry write route, cookies, sessions,
  database, or writable application volume.
- Responses use no-store caching for API/health and a restrictive same-origin
  CSP, `nosniff`, and no-referrer policy. Embedded assets use strong ETags.
- The Compose image uses a pinned Go builder and scratch runtime, includes the
  builder CA bundle, runs as a numeric non-root user, and has no shell or
  package manager. Victoria backend ports remain Docker-internal.
- The Dashboard shares a dedicated Docker network with Gateway; the sample app
  and Victoria stores do not join that network.

## Testing and formatting

From this directory:

```bash
gofmt -w $(find cmd internal -name '*.go' -type f)
go test ./...
go test -race ./...
go vet ./...
go build -trimpath -ldflags='-s -w' -o /tmp/agentotel-dashboard ./cmd/dashboard
```

The repository uses the pinned `golang:1.26.6-bookworm` Docker image for
portable CI checks when a compatible host Go toolchain is unavailable. Tests
cover startup validation, embedded-asset traversal, loopback health,
strict input, fixed-scope proxying, redaction, response limits, normalization,
and the `dashboard.v1` view model.

## Split guidance

If this module moves to another repository, move it as a unit, including
`LICENSE`, `go.mod`, `Dockerfile`, `cmd/dashboard`, `internal/proxy`,
`internal/ui`, and the embedded `internal/ui/static` tree. Keep the standard
library-only implementation and the `dashboard.v1` response contract. The
consuming Compose/deployment layer must continue to supply a fixed workspace
project ID, server-side query credential, and separate browser client token;
publish only the Dashboard host port and keep Victoria APIs private. A split
must not add raw query, telemetry-write, CORS, arbitrary proxy, or persistent
browser/dashboard state.
