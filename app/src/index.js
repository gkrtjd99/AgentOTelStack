// Sample business logic under observation.
//
// Instrumentation is zero-code: the process is started with
//   node --require @opentelemetry/auto-instrumentations-node/register
// which wires up OTLP traces, metrics, and logs from OTEL_* env vars
// (see docker-compose.yml). The pino instrumentation bridges these logs
// to OTLP automatically, so app logs land in VictoriaLogs with trace_id.

const express = require("express");
const pinoHttp = require("pino-http");
const { metrics, trace } = require("@opentelemetry/api");

const path = require("path");

const app = express();
const logger = require("pino")({ level: "info" });
app.use(pinoHttp({ logger }));

// Minimal UI so the e2e runner has a real browser journey to drive.
app.use(express.static(path.join(__dirname, "..", "public")));

// A custom business metric so PromQL has something app-specific to query.
const meter = metrics.getMeter("sample-app");
const ordersCounter = meter.createCounter("orders_processed_total", {
  description: "Number of orders processed, by outcome",
});
const orderLatency = meter.createHistogram("order_processing_seconds", {
  description: "Order processing latency in seconds",
  unit: "s",
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.get("/health", (_req, res) => res.json({ status: "ok" }));

// Healthy path: emits a span, a log line, and metrics.
app.get("/api/orders/:id", async (req, res) => {
  const start = process.hrtime.bigint();
  const span = trace.getActiveSpan();
  const id = req.params.id;
  span?.setAttribute("order.id", id);

  // Simulate variable work.
  const work = 20 + Math.floor(Math.random() * 120);
  await sleep(work);

  req.log.info({ orderId: id, workMs: work }, "order processed");
  ordersCounter.add(1, { outcome: "success" });
  orderLatency.record(Number(process.hrtime.bigint() - start) / 1e9, {
    outcome: "success",
  });
  res.json({ orderId: id, processedInMs: work });
});

// Failure path: deliberately produces errors so agents have something to debug.
// Hit /api/checkout?fail=1 to force a 500 with an error span + error log.
app.get("/api/checkout", async (req, res) => {
  const start = process.hrtime.bigint();
  const span = trace.getActiveSpan();
  const forced = req.query.fail === "1";
  const flaky = Math.random() < 0.15; // 15% baseline error rate

  await sleep(10 + Math.floor(Math.random() * 40));

  if (forced || flaky) {
    const err = new Error("payment gateway timeout");
    span?.recordException(err);
    span?.setStatus({ code: 2, message: err.message }); // ERROR
    req.log.error({ err: err.message, forced }, "checkout failed");
    ordersCounter.add(1, { outcome: "error" });
    orderLatency.record(Number(process.hrtime.bigint() - start) / 1e9, {
      outcome: "error",
    });
    return res.status(500).json({ error: err.message });
  }

  req.log.info("checkout succeeded");
  ordersCounter.add(1, { outcome: "success" });
  orderLatency.record(Number(process.hrtime.bigint() - start) / 1e9, {
    outcome: "success",
  });
  res.json({ status: "paid" });
});

const port = Number(process.env.PORT || 3000);
app.listen(port, () => {
  logger.info({ port }, "sample-app listening");
});
