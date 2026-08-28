# Dashboard and terminal overview

[English](./DASHBOARD.md) · [한국어](./ko/DASHBOARD.md)

The Go Dashboard is the repository's sole browser UI. It is an optional human
inspection console; the authenticated `obs/*.sh` helpers and terminal overview
remain the authoritative agent interface.

## Terminal overview

The terminal overview presents the Gateway's bounded `GET /v1/context` envelope:

```bash
make overview SERVICE=sample-app MODE=compact LOOKBACK=15m
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --compact --lookback 15m sample-app
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --json --since 1h sample-app
```

Allowed lookbacks are exactly `5m`, `15m`, `1h`, `6h`, and `24h`; `30m` is not a
supported value. The overview does not promise a business metric, an orders
ratio, p95 latency, or a particular backend result shape. For one failure, take
a 32-hex trace ID from the evidence and use
`./obs/correlate.sh <trace-id>` through the credential runner.

## Start the browser Dashboard

The stable checkout-owned lifecycle is Make-only:

```bash
make dashboard
# open the exact `dashboard bootstrap URL: .../#token=...` line
make dashboard-down
```

`make dashboard` force-recreates the Dashboard service for the checkout's
stable Compose project, generates a fresh cryptographically secure client token,
proves Gateway-backed readiness, and prints one bootstrap URL. The default host
binding is loopback `http://127.0.0.1:3001`; `DASHBOARD_HOST_PORT` may select a
deliberate alternate loopback port. Open the printed fragment URL, not the
fragment-free base URL. The browser consumes the fragment, replaces it with
`#overview`, keeps the token only in memory, and sends it only in a Dashboard
Authorization header. A full reload intentionally requires reopening the
printed URL.

The client credential is exactly 64 lowercase hexadecimal characters and is
different from the Gateway query token. It is not persisted in the canonical
credential file, static assets, HTML, cookies, Web Storage, request query
parameters, or logs. The Gateway query token and fixed workspace project remain
server-side. Static assets and local health are public; `/api/*` requests
without the client credential receive a generic 401.

For a direct source Compose start, provide a valid distinct token yourself; the
binary does not expose a token endpoint:

```bash
export DASHBOARD_CLIENT_TOKEN=<64-lowercase-hex-token>
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile dashboard up -d --build dashboard
# open http://127.0.0.1:3001/#token=$DASHBOARD_CLIENT_TOKEN
```

The supported Make path is preferred because it owns project resolution,
credential injection, readiness, and the printed bootstrap URL. `make
 dashboard-down` stops only the Dashboard service. `make dev-down` stops both
optional profiles while preserving telemetry volumes.

## Bounded API

The Dashboard is a same-origin server-side adapter. It exposes only these
read routes:

| Route | Method | Bounded input |
| --- | --- | --- |
| `/api/services` | `GET` | No query parameters |
| `/api/context` | `GET` | `service`, `lookback`, and `limit` |
| `/api/errors` | `GET` | `service`, `lookback`, and `limit` |
| `/api/correlate` | `POST` | JSON `trace_id` and optional bounded `limit` |
| `/health` | `GET` | Loopback callers, no query string |
| `/` and `/assets/*` | `GET`, `HEAD` | Embedded, validated assets |

Every `/api/*` route requires exactly one
`Authorization: Dashboard <64-lowercase-hex-token>` header. Unknown or duplicate
JSON fields, unknown query parameters, invalid service names, invalid lookbacks,
malformed trace IDs, and out-of-range limits are rejected before the Gateway is
contacted. The proxy supplies only the fixed workspace project and server-side
Gateway query credential. It exposes no raw LogQL/PromQL/Jaeger query, telemetry
write route, arbitrary backend URL, CORS proxy, or browser project selector.

The Dashboard preserves `partial`, `truncated`, no-data, and backend status
states as evidence. It is a bounded operating console, not a general
visualization or historical time-series product. Use [`QUERY.md`](./QUERY.md)
for the Gateway contract and the shell helpers for agent workflows.

## Runtime hardening

`src/dashboard` is a split-ready Go module using the standard library and
embedded static assets. The Compose image is built from a pinned Go builder and
runs as a non-root numeric user in a scratch image with the builder CA bundle,
no shell/package manager, no writable application volume, and a self-health
probe. The Dashboard and Gateway share a dedicated network; the app and Victoria
stores do not join it. Victoria backend ports remain Docker-internal.

The module is stateless: no telemetry write route, cookies, sessions, persistent
browser state, or database. Upstream redirects are not followed and response
and request sizes are bounded. See [`SECURITY.md`](./SECURITY.md) for the
threat model and [`../src/dashboard/README.md`](../src/dashboard/README.md) for
module build/configuration details.

## Browser E2E lifecycle

Playwright journeys are deliberately Make-managed so they cannot silently run
against stale services:

```bash
make e2e             # demo + Dashboard profiles, complete suite
make e2e-app         # demo profile, sample-app journey only
make e2e-dashboard   # dashboard spec only; starts demo + Dashboard profiles
```

Direct `cd e2e && npm test` is unsupported. The Make-owned runner selects an
isolated project, creates the required labeled volumes, starts the profiles,
waits for app/Gateway/Dashboard evidence, and cleans up its resources. The
Dashboard journey needs the demo app because it exercises live errors and trace
correlation even though only `dashboard.spec.js` is selected.
