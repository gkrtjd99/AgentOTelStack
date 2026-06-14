# Security Notes

This repository is designed as a local development observability stack. The
default and optional profiles publish unauthenticated HTTP ports on
`localhost`:

| Port | Service | Risk if exposed |
|---|---|---|
| 4317 / 4318 | OTLP ingest | Any reachable client can send telemetry |
| 8428 | VictoriaMetrics | Metrics can be queried and modified via API |
| 9428 | VictoriaLogs | Logs can be queried |
| 10428 | VictoriaTraces | Traces can be queried |
| 3000 | sample-app demo | Demo app endpoint, only with `make demo` |
| 3001 | Grafana | Optional dashboard profile; anonymous viewer enabled |

## Recommended Local Use

- Run on a trusted developer machine.
- Keep Docker port bindings on localhost or a private interface.
- Keep Grafana behind the optional `dashboard` profile unless a browser
  dashboard is needed.
- Do not send secrets, tokens, credentials, or personal data in logs, span
  attributes, metric labels, or exception messages.
- Use `make clean` when you need to wipe local stored telemetry.
- Treat Docker volumes as local data stores. Stopping the stack with
  `make down` preserves telemetry.

## Remote or Shared Use

If you deliberately expose this stack beyond the local machine, put it behind a
proper boundary first:

- bind published ports to a private interface or VPN-only address
- terminate TLS at a reverse proxy
- require authentication at the proxy
- restrict inbound OTLP ingestion to trusted apps
- define retention and redaction policies before collecting real user data

The compose file intentionally does not include production auth, TLS, or
multi-tenant controls. Add those outside this repo if the stack leaves a local
developer environment.

## Image Pinning

Runtime images are pinned by digest in `docker-compose.yml`, and the sample app
base image is pinned by digest in `app/Dockerfile`. The sample app dependencies
are locked with `app/package-lock.json` and installed with `npm ci`.

Refresh image pins and dependency locks intentionally, then run:

```bash
cd app && npm audit --omit=dev --audit-level=high
docker compose --profile demo --profile dashboard config
make smoke
```

That keeps dependency updates visible and testable instead of silently following
moving `latest` tags.
