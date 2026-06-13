# Connecting your own apps (bring-your-own-app)

This stack is shared local observability infra. Run it once; point any number of
your own projects at it. Each app just needs to **emit OTLP to the collector**.

## The contract (only 3 things)

Your app — running on your host (`npm run dev`, `python app.py`, `go run .`, …) —
sets these environment variables:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # the collector (ports published to host)
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app                            # unique per app — this is how you filter later
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

Then start the infra:

```bash
make up        # collector + VictoriaLogs/Metrics/Traces only (no sample app)
```

That's it for networking — `4317` (gRPC) and `4318` (HTTP) are published to
`localhost`. Multiple apps with different `OTEL_SERVICE_NAME` all fan into the
same stores and are queried side by side.

---

## Per-language setup

### Node.js / TypeScript

Reuse the bootstrap from this repo — copy `app/src/otel.js` into your project and:

```bash
npm i @opentelemetry/api @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-proto \
  @opentelemetry/exporter-metrics-otlp-proto \
  @opentelemetry/exporter-logs-otlp-proto \
  @opentelemetry/sdk-metrics @opentelemetry/sdk-logs

# start your app with the bootstrap preloaded:
node --require ./otel.js your-entry.js
```

> Why the explicit `otel.js` instead of `--require @opentelemetry/auto-instrumentations-node/register`?
> In this SDK generation the register shortcut wires up traces + logs but **not metrics**.
> The explicit bootstrap guarantees all three. (Traces/logs only? `register` is fine.)

### Python

Zero-code auto-instrumentation covers traces, metrics, and logs:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install            # installs instrumentations for your libs

OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
OTEL_SERVICE_NAME=my-py-app \
OTEL_LOGS_EXPORTER=otlp \
opentelemetry-instrument python app.py
```

### Go

No auto-instrumentation — set up the SDK in `main()` with the OTLP/HTTP exporters
(`go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp`,
`.../otlpmetric/otlpmetrichttp`, `.../otlplog/otlploghttp`) reading the same
`OTEL_EXPORTER_OTLP_ENDPOINT`. Use `otelhttp`/`otelgin` middleware for HTTP spans.

### Java

```bash
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.exporter.otlp.endpoint=http://localhost:4318 \
  -Dotel.exporter.otlp.protocol=http/protobuf \
  -Dotel.service.name=my-java-app \
  -jar your-app.jar
```

### Any other language

If the SDK speaks OTLP/HTTP, the same four env vars work. The collector accepts
standard OTLP at `:4318` (HTTP) and `:4317` (gRPC) — nothing here is app-specific.

---

## Querying when you have multiple apps

Everything lands in the same stores; filter by service name:

```bash
# logs for one app
./obs/logs.sh '_time:15m service.name:my-app severity_text:error'

# metrics for one app (OTLP attrs become labels; dots -> underscores)
./obs/metrics.sh 'sum by (outcome) (some_metric{service_name="my-app"})'

# traces for one app
./obs/traces.sh search my-app
./obs/traces.sh services          # see every service currently reporting
```

So your laptop ends up with one always-on observability backend that every local
project reports into — and any agent reads it through `./obs/*.sh` + `AGENTS.md`.

---

## Lifecycle

```bash
make up        # infra only (your apps connect from the host)
make demo      # also run the bundled sample app, if you want a reference
make down      # stop
make clean     # stop + wipe stored telemetry
```
