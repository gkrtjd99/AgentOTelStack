// Explicit OpenTelemetry bootstrap (loaded via `node --require ./src/otel.js`).
//
// We configure the SDK by hand rather than relying on the auto-register entry
// point because, in this SDK generation, the register shortcut wires up traces
// and logs but NOT metrics. Doing it explicitly guarantees all three signals
// flow and documents exactly what the app emits.
//
// Endpoint/protocol/service.name/resource attrs are read from OTEL_* env vars
// (see docker-compose.yml).

const { NodeSDK } = require("@opentelemetry/sdk-node");
const {
  getNodeAutoInstrumentations,
} = require("@opentelemetry/auto-instrumentations-node");
const {
  OTLPTraceExporter,
} = require("@opentelemetry/exporter-trace-otlp-proto");
const {
  OTLPMetricExporter,
} = require("@opentelemetry/exporter-metrics-otlp-proto");
const { OTLPLogExporter } = require("@opentelemetry/exporter-logs-otlp-proto");
const { PeriodicExportingMetricReader } = require("@opentelemetry/sdk-metrics");
const { BatchLogRecordProcessor } = require("@opentelemetry/sdk-logs");

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: Number(
      process.env.OTEL_METRIC_EXPORT_INTERVAL || 10000
    ),
  }),
  logRecordProcessors: [new BatchLogRecordProcessor(new OTLPLogExporter())],
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

process.on("SIGTERM", () => {
  sdk.shutdown().finally(() => process.exit(0));
});
