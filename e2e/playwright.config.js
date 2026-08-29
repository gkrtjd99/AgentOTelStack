// @ts-check
const crypto = require("crypto");
const fs = require("fs");
const { defineConfig } = require("@playwright/test");

const mode = process.env.AGENTOTEL_E2E_MODE;
const expectedDashboardStatus = mode === "all" || mode === "dashboard" ? "ready" : "not_required";

function validateReadiness(readiness) {
  if (
    readiness.version !== 1 ||
    readiness.kind !== "agentotel.e2e-ready.v1" ||
    readiness.mode !== mode ||
    readiness.dashboard_status !== expectedDashboardStatus ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(readiness.project_id || "") ||
    !/^[a-z0-9][a-z0-9_-]{0,62}$/.test(readiness.compose_project || "") ||
    !/^[0-9a-f]{32}$/.test(readiness.nonce || "") ||
    !Number.isInteger(readiness.issued_at) ||
    Math.abs(Date.now() / 1000 - readiness.issued_at) > 600
  ) {
    throw new Error("Invalid or stale E2E readiness capability shape");
  }
  if (
    process.env.AGENTOTEL_PROJECT_ID &&
    readiness.project_id !== process.env.AGENTOTEL_PROJECT_ID
  ) {
    throw new Error("E2E readiness capability project does not match the lifecycle");
  }
  if (
    process.env.COMPOSE_PROJECT_NAME &&
    readiness.compose_project !== process.env.COMPOSE_PROJECT_NAME
  ) {
    throw new Error("E2E readiness capability Compose project does not match the lifecycle");
  }
}

// Playwright worker processes reopen this config after allocating their own
// descriptors, so FD 9 is no longer reliable there. The main process proves
// the lifecycle capability once and hands workers a fresh, process-generated
// token; direct npm invocations still fail before any worker can start.
if (process.env.TEST_WORKER_INDEX === undefined) {
  const readyFdValue = process.env.AGENTOTEL_E2E_READY_FD;
  if (!/^[3-9][0-9]*$/.test(readyFdValue || "")) {
    throw new Error(
      "Direct npm E2E invocation is unsupported: run `make e2e`, `make e2e-app`, or `make e2e-dashboard`; the Make lifecycle must hand Playwright an inherited readiness capability.",
    );
  }

  let readiness;
  try {
    readiness = JSON.parse(fs.readFileSync(Number(readyFdValue), "utf8"));
  } catch (error) {
    throw new Error(`Invalid inherited E2E readiness capability: ${error.message}`);
  }
  validateReadiness(readiness);
  process.env.AGENTOTEL_E2E_READY_VERIFIED = crypto.randomBytes(32).toString("hex");
} else if (!/^[0-9a-f]{64}$/.test(process.env.AGENTOTEL_E2E_READY_VERIFIED || "")) {
  throw new Error("Missing Playwright worker readiness handoff");
}

module.exports = defineConfig({
  testDir: ".",
  timeout: 30_000,
  use: {
    baseURL: process.env.APP_URL || "http://localhost:3000",
    headless: true,
  },
  reporter: [["list"]],
});
