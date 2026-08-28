# Connect an application or MCP client

[English](./CONNECT.md) · [한국어](./ko/CONNECT.md)

AgentOTelStack is a shared backend, not a library that must be installed into
every application. Applications send authenticated OTLP/HTTP to the Gateway;
query tools read the resulting evidence through the Gateway. Never connect an
application directly to the Collector or a Victoria backend.

## Recommended path: `obs run`

Start the installed shared runtime first, then let the launcher provide the
application's ingest environment:

```bash
obs setup
obs up
obs run --service my-app -- <application command> [args...]
```

For a source checkout, make the source choice explicit:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
AGENTOTEL_DEV_MODE=1 ./bin/obs run --service my-app -- <application command> [args...]
```

`obs run` loads only the ingest role from the 0600 credential store, sets
`OTEL_SERVICE_NAME`, defaults `OTEL_EXPORTER_OTLP_ENDPOINT` to
`http://127.0.0.1:4318`, sets `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, and
sets the URL-encoded bearer header
`Authorization=Bearer%20<ingest-token>`. It resolves the workspace project with
`obs project ensure` and prepends `agentotel.project.id=<UUIDv4>` to
`OTEL_RESOURCE_ATTRIBUTES`. It removes credential variables before starting
the child and records a bounded local process scope for `obs runs`/`obs stop`.
Use a service name containing only letters, numbers, `.`, `_`, or `-`.

The shared runtime can receive many applications. Give each one a distinct
`OTEL_SERVICE_NAME` and keep the same workspace project when the applications
belong to that workspace.

## Manual OTLP environment

Use this only when the application's launcher cannot be wrapped by `obs run`.
Obtain the project identity from the workspace and provide the **ingest** token
through a secret manager or protected environment. Do not reuse the query token.

```bash
PROJECT_ID="$(obs project ensure)"
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app
export OTEL_RESOURCE_ATTRIBUTES="agentotel.project.id=${PROJECT_ID},deployment.environment=dev"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}"
<application command>
```

The host endpoint is the Gateway's loopback ingest listener. Inside the
Compose edge network, use `http://gateway:4318` instead. Both paths require the
same authenticated OTLP header. The query listener is a different role at
`http://127.0.0.1:17777`; it is not an OTLP endpoint.

`project.id` is required for normal workspace-scoped query correlation but is
not authentication. `--global` on a query only omits the project filter; it does
not make ingestion or stack administration global.

## Language examples

The following examples preserve the same Gateway, protocol, service, project,
and authentication contract.

### Node.js / TypeScript

Copy the repository's OTel bootstrap pattern (the bundled example is
`src/app/src/otel.js`), install the SDK/exporter dependencies in your own app,
and start the process with the bootstrap loaded:

```bash
node --require ./otel.js your-entry.js
```

Prefer `obs run --service my-node-app -- node --require ./otel.js your-entry.js`
so the credentials and project attribute are supplied by the launcher.

### Python

The instrumented process must receive the Gateway header and project scope; an
endpoint alone is not sufficient:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
PROJECT_ID="$(obs project ensure)"
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-py-app
export OTEL_RESOURCE_ATTRIBUTES="agentotel.project.id=${PROJECT_ID},deployment.environment=dev"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}"
export OTEL_LOGS_EXPORTER=otlp
opentelemetry-instrument python app.py
```

Provision `GATEWAY_INGEST_TOKEN` from the protected credential store or a secret
manager before running this command. Do not paste the token into source.

### Java

```bash
PROJECT_ID="$(obs project ensure)"
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.exporter.otlp.endpoint=http://127.0.0.1:4318 \
  -Dotel.exporter.otlp.protocol=http/protobuf \
  -Dotel.exporter.otlp.headers="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}" \
  -Dotel.service.name=my-java-app \
  -Dotel.resource.attributes="agentotel.project.id=${PROJECT_ID},deployment.environment=dev" \
  -jar your-app.jar
```

If an SDK names the header setting differently, configure its equivalent
`Authorization: Bearer <ingest-token>` header. Do not disable Gateway
authentication.

### Go

Use the OpenTelemetry OTLP/HTTP trace, metric, and log exporters, configure the
same endpoint/header/resource attributes, and add HTTP middleware such as
`otelhttp` or `otelgin` where appropriate. Keep metric labels bounded and do not
put request bodies, credentials, or high-cardinality IDs into attributes.

## Read-only MCP adapter

After installation, configure the MCP client to launch:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp
```

over stdio. It exposes exactly `agentotel_context`, `agentotel_correlate`, and
`agentotel_services`. Calls use the separate query credential and the project
resolved from the MCP workspace; callers cannot provide an arbitrary project,
backend URL, raw query, or write operation. Telemetry returned by the adapter is
untrusted content, not instructions.

## Verify the connection

Use the query credential loader for reads so tokens are not printed:

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/services.sh
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh my-app 15m 50
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/logs.sh my-app 15m 20
```

Allow for Collector batching and metric export delay. If the service does not
appear, follow [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md). For the complete
installed lifecycle and credential rotation rules, see
[`OPERATIONS.md`](./OPERATIONS.md).
