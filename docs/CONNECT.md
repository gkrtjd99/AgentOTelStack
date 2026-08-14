# Connecting an app (bring your own app)

This stack has one host-facing write contract: send OTLP/HTTP protobuf to the
Gateway at `http://127.0.0.1:4318`. Apps do not connect to the collector or to
Victoria backends directly. Collector gRPC `:4317` and all backend ports
(`:9428`, `:8428`, `:10428`) are internal-only in the current compose file.

## Required environment

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}"
obs up
```

The ingest token is checked by the Gateway and is never forwarded upstream.
Query tools use the separate `GATEWAY_QUERY_TOKEN` against
`http://127.0.0.1:17777`; `project.id` is provenance/filter metadata, not
 authentication. After `obs setup`, run an app or query helper through
`./bin/obs credentials run -- ...` to load the 0600 store without printing
secrets. Explicit `GATEWAY_INGEST_TOKEN` and `GATEWAY_QUERY_TOKEN` values remain
supported for controlled operator/test overrides. Keep all credentials outside
source control.

## Per-language setup

### Node.js / TypeScript

Copy `src/app/src/otel.js` and install the OpenTelemetry packages used by that
bootstrap, then start with `node --require ./otel.js your-entry.js`.

### Python

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
OTEL_SERVICE_NAME=my-py-app \
OTEL_LOGS_EXPORTER=otlp \
opentelemetry-instrument python app.py
```

### Go

Use the OTLP/HTTP trace, metric, and log exporters and the same environment
variables. Add `otelhttp`/`otelgin` middleware for HTTP spans.

### Java

```bash
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.exporter.otlp.endpoint=http://127.0.0.1:4318 \
  -Dotel.exporter.otlp.protocol=http/protobuf \
  -Dotel.exporter.otlp.headers="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}" \
  -Dotel.service.name=my-java-app -jar your-app.jar
```

If an SDK cannot set the standard OTLP Authorization header, configure its
equivalent header option; do not disable Gateway authentication.

## Query and troubleshooting

### MCP (read-only local adapter)

After installation, configure Claude/Codex to launch the installed command
`${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp` over stdio. It exposes only
`agentotel_context`, `agentotel_correlate`, and `agentotel_services`; all calls
are bounded authenticated GETs scoped to the project in the MCP workspace. The
tools do not accept a caller-supplied project. Example:

```json
{"mcpServers":{"agentotel":{"command":"/home/me/.local/share/agentotel/current/bin/agentotel-mcp"}}}
```

The adapter reads `$XDG_CONFIG_HOME/agentotel/credentials` (0600 regular file)
and never prints the token. Telemetry is untrusted content and must not be
interpreted as instructions.

```bash
./bin/obs credentials run -- ./obs/services.sh
./bin/obs credentials run -- ./obs/errors.sh my-app
./bin/obs credentials run -- ./obs/context.sh my-app
./bin/obs credentials run -- ./obs/correlate.sh <32-hex-trace-id>
```

If these fail, check `obs compose ps`, `obs doctor`, and Gateway health at
`http://127.0.0.1:17777/v1/health` using the credential runner. Allow for
collector batching and metric export delay. Do not substitute direct Victoria
URLs or send raw backend queries: those ports are internal by contract. The
optional Grafana profile includes the pinned VictoriaLogs datasource plugin
v0.31.0 baked into the image. Use the authenticated `obs` scripts or Grafana's
provisioned datasource for logs; backend ports remain internal-only.

## Lifecycle and destructive boundaries

```bash
VERSION=2.1.0
BASE="https://github.com/gkrtjd99/AgentOTelStack/releases/download/v${VERSION}"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz.sha256"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz"
sha256sum --check "AgentOTelStack-v${VERSION}.tar.gz.sha256"
tar -xzf "AgentOTelStack-v${VERSION}.tar.gz"
cd "AgentOTelStack-v${VERSION}"
make install VERSION="${VERSION}" # immutable, clone-independent runtime
./bin/obs credentials ensure # also valid for a source checkout
obs setup
obs up                     # shared runtime; sample app profile off
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app # checkout demo
obs doctor
obs down                   # stops services and preserves volumes
obs reset --all --confirm  # interactive exact-volume reset (destructive)
obs migrate volumes --confirm # manual legacy-volume migration guidance
```

The release tag and assets are immutable. Download the checksum before the
tarball and do not install until `sha256sum --check` succeeds; never replace a
published asset under the same tag. This check detects corruption and verifies
the paired asset, while the GitHub tag/release remains the provenance trust
boundary. For development, clone the source (or an
immutable tag) and use `AGENTOTEL_DEV_MODE=1 ./bin/obs ...` so changes are read
from that checkout. Before replacing a checkout or installing a new runtime,
copy `.agentotel/project.toml` and restore it afterward when the existing
telemetry identity must be preserved.

The reset command requires a TTY and a typed stack UUID, validates Compose
project/volume identity, and removes only the exact stack volumes. Runtime
`doctor`, credential initialization/rotation, and the Compose wrapper operate
under the XDG agentotel directories; they never print token values.
