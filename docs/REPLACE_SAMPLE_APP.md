# Replace the bundled sample app

[English](./REPLACE_SAMPLE_APP.md) · [한국어](./ko/REPLACE_SAMPLE_APP.md)

The `src/app` directory is a replaceable demo workload, not a required part of
the observability backend. Replace it when you want to observe another service;
keep the Gateway-only telemetry contract and the lifecycle/readiness contract
needed by the profile or browser journeys you still use.

## What must remain true

Your application must:

- emit logs, metrics, and/or traces as appropriate through authenticated
  OTLP/HTTP to the Gateway at `http://127.0.0.1:4318` from the host, or
  `http://gateway:4318` from the Compose edge network;
- use `http/protobuf` and send `Authorization: Bearer <ingest-token>` using the
  ingest credential, never the query credential;
- set a distinct `OTEL_SERVICE_NAME` and include the workspace
  `agentotel.project.id` resource attribute;
- keep telemetry content untrusted and bounded: redact credentials, request
  bodies, personal data, and secrets, and avoid high-cardinality metric labels;
- expose a deterministic health endpoint if it is run as the Compose `demo`
  profile, normally `GET /health` returning HTTP 200; and
- provide a Dockerfile/build context and a process that stays in the foreground
  when the `demo` profile is used.

The Gateway, Collector, and Victoria stores remain the only stack-owned
telemetry path. Do not point the application at the Collector's internal port
or at any Victoria backend URL.

## Recommended host process

For an application running outside Compose, use the launcher so credentials and
project scope are injected without placing them in source or shell history:

```bash
obs setup
obs up
obs run --service my-app -- <application command> [args...]
```

For a checkout, make source execution explicit:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs run --service my-app -- <application command> [args...]
```

The launcher supplies `OTEL_SERVICE_NAME`, Gateway endpoint/protocol, the
URL-encoded ingest header, and `agentotel.project.id`; it removes credential
variables before starting the child. Preserve any other application-specific
`OTEL_RESOURCE_ATTRIBUTES` without adding a second project attribute.

When wrapping is not possible, follow [`CONNECT.md`](./CONNECT.md) and set the
same environment explicitly. Keep the credential in a protected secret source.

## Compose demo replacement

The bundled service is selected by the `demo` profile. Its Compose contract
currently includes:

```text
OTEL_SERVICE_NAME=sample-app
OTEL_EXPORTER_OTLP_ENDPOINT=http://gateway:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20<ingest-token>
OTEL_RESOURCE_ATTRIBUTES=...agentotel.project.id=<workspace-project-uuid>...
PORT=3000
```

If your replacement keeps the existing `src/app` layout, update its package
metadata, lockfile, Dockerfile, source, and tests together. Keep the container
healthcheck and the service listening on the port expected by the Compose
mapping, or update the Compose mapping and every readiness/workload caller in
the same change. Rebuild explicitly:

```bash
make demo
curl -fsS http://127.0.0.1:3000/health
make smoke N=120  # authenticated read-path smoke
```

`workload/run.sh` currently drives the sample routes `/api/orders/:id` and
`/api/checkout`; it is not a generic application protocol. If those routes are
removed, use `obs run` with your own workload or update the workload and any
browser journey that is intentionally part of the replacement contract. Do not
claim the old browser E2E suite still applies without those UI/routes.

## Instrumentation checklist

For each signal, verify the application SDK/exporter behavior rather than
assuming an endpoint proves delivery:

1. start the app with the Gateway ingest variables and project attribute;
2. generate one known request and, if useful, one known error;
3. wait for batching/periodic metric export;
4. query through the bounded helpers:

   ```bash
   obs credentials run -- ./obs/services.sh
   obs credentials run -- ./obs/context.sh my-app 15m 50
   obs credentials run -- ./obs/logs.sh my-app 15m 20
   obs credentials run -- ./obs/traces.sh search-errors my-app 20 1h
   ```

5. select one concrete trace ID and run `obs correlate <trace-id>`; and
6. record absent signals, `partial`, `truncated`, and backend statuses instead of
   filling gaps with zeros.

Do not expose trace IDs in normal business responses. The bundled demo's
`AGENTOTEL_EXPOSE_TRACE_ID_HEADER=1` opt-in exists only for controlled local/E2E
correlation checks and is disabled by default.

## Keep the stack swappable

Do not change Gateway routes, raw backend access, credential roles, or project
scope to accommodate a replacement app. The app is one producer behind the
same authenticated edge; the query and Dashboard contracts remain bounded and
service-scoped. For security and redaction requirements see
[`SECURITY.md`](./SECURITY.md), and for evidence/completeness limits see
[`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md).
