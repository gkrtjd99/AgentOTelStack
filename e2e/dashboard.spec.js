// @ts-check
const { test, expect } = require("@playwright/test");

const dashboardURL = process.env.DASHBOARD_URL || "http://localhost:3001";
const clientToken = process.env.DASHBOARD_E2E_AUTH_TOKEN || "";
const bootstrapURL = process.env.DASHBOARD_BOOTSTRAP_URL || `${dashboardURL}/#token=${clientToken}`;
const traceID = process.env.DASHBOARD_TRACE_ID || "";
const live = process.env.DASHBOARD_E2E_LIVE === "1";
if (live && !/^[0-9a-f]{64}$/.test(clientToken)) {
  throw new Error("Live dashboard E2E requires the generated dashboard client token");
}
if (live && !/^https?:\/\/[^#]+\/#token=[0-9a-f]{64}$/.test(bootstrapURL)) {
  throw new Error("Live dashboard E2E requires a valid dashboard bootstrap URL");
}
if (live && !/^[0-9a-f]{32}$/.test(traceID)) {
  throw new Error("Live dashboard E2E requires DASHBOARD_TRACE_ID from the exact forced checkout response");
}

const operationalFailures = new Set([
  "backend_unavailable",
  "timeout",
  "backend_decode_error",
  "backend_integrity_error",
  "unsupported",
  "partial",
  "telemetry_incomplete",
]);

function assertHealthyView(view, kind, expectedBackends) {
  expect(view.schema_version, `${kind} schema`).toBe("dashboard.v1");
  expect(view.kind, `${kind} kind`).toBe(kind);
  expect(view.scope && view.scope.project_bound, `${kind} project scope`).toBe(true);
  expect(view.partial, `${kind} partial`).toBe(false);
  expect(Array.isArray(view.backends), `${kind} backend statuses`).toBe(true);
  const names = new Set(view.backends.map((backend) => backend.name));
  for (const backend of expectedBackends) expect(names.has(backend), `${kind} backend ${backend}`).toBe(true);
  for (const backend of view.backends) {
    expect(operationalFailures.has(backend.status), `${kind} backend ${backend.name} status`).toBe(false);
  }
}

function dashboardAuthHeaders() {
  return { Authorization: `Dashboard ${clientToken}` };
}

function envelope(kind, overrides = {}) {
  return {
    schema_version: "dashboard.v1",
    kind,
    fetched_at: "2026-01-01T00:00:00Z",
    partial: false,
    truncated: false,
    content_trust: "untrusted_telemetry",
    backends: [
      { name: "logs", status: "ok" },
      { name: "metrics", status: "ok" },
    ],
    scope: { project_bound: true },
    data: {},
    ...overrides,
  };
}

test.describe("dashboard journey", () => {
  test("overview, service selection, bounded errors, and trace detail", async ({ page, request }) => {
    await page.goto(bootstrapURL);
    await expect(page.getByRole("heading", { name: "System signals, without the noise." })).toBeVisible();
    await expect(page.locator("#service-select")).toBeVisible();

    await page.getByRole("link", { name: "Services" }).click();
    await expect(page.getByRole("heading", { name: "Observed service names" })).toBeVisible();
    const servicesResponse = await request.get(`${dashboardURL}/api/services`, { headers: dashboardAuthHeaders() });
    expect(servicesResponse.ok()).toBeTruthy();
    const servicesBody = await servicesResponse.json();
    assertHealthyView(servicesBody, "services", ["logs", "metrics"]);
    const serviceSelect = page.locator("#service-select");
    await expect(serviceSelect.locator('option[value="sample-app"]')).toHaveCount(1);
    await serviceSelect.selectOption("sample-app");
    await expect(serviceSelect).toHaveValue("sample-app");

    await page.getByRole("link", { name: "Errors" }).click();
    await expect(page.getByRole("heading", { name: "Recent failures" })).toBeVisible();
    const limited = await request.get(`${dashboardURL}/api/errors?service=sample-app&lookback=5m&limit=1`, { headers: dashboardAuthHeaders() });
    expect(limited.ok()).toBeTruthy();
    const limitedBody = await limited.json();
    assertHealthyView(limitedBody, "errors", ["logs", "traces"]);
    expect(Array.isArray(limitedBody.data.errors)).toBeTruthy();
    expect(limitedBody.data.errors.length).toBeLessThanOrEqual(1);

    expect(traceID).toMatch(/^[0-9a-f]{32}$/);
    await page.getByRole("link", { name: "Trace detail" }).click();
    await page.locator("#trace-input").fill(traceID);
    await page.getByRole("button", { name: "Load trace" }).click();
    await expect(page.locator("#trace-fetched")).not.toHaveText("Not fetched", { timeout: 10_000 });
    await expect(page.getByRole("heading", { name: "Follow one request" })).toBeVisible();
    await expect(page.locator("#trace-table")).toContainText(/No known spans returned|sample-app|checkout|order/i);
    const correlation = await request.post(`${dashboardURL}/api/correlate`, {
      data: { trace_id: traceID },
      headers: { "Content-Type": "application/json", ...dashboardAuthHeaders() },
    });
    expect(correlation.ok()).toBeTruthy();
    const correlationBody = await correlation.json();
    assertHealthyView(correlationBody, "correlate", ["traces", "logs", "metrics"]);
    expect(correlationBody.data.trace_id).toBe(traceID);
  });

  test("partial and no-data states remain visible and bounded", async ({ page }) => {
    await page.route("**/api/context*", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(envelope("context", {
          partial: true,
          backends: [
            { name: "logs", status: "backend_unavailable" },
            { name: "metrics", status: "ok" },
          ],
          scope: { service: "sample-app", lookback: "15m", limit: 50, project_bound: true },
          data: { supported: true, logs: [], metrics: [] },
        })),
      });
    });
    await page.route("**/api/services", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(envelope("services", {
          data: { supported: true, services: ["sample-app"] },
        })),
      });
    });
    await page.goto(bootstrapURL);
    await expect(page.getByText("Some backend signals are unavailable. This view is partial.")).toBeVisible();
    await expect(page.getByText("No known log records in this response.")).toBeVisible();

    await page.unroute("**/api/context*");
    await page.route("**/api/errors*", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(envelope("errors", {
          scope: { service: "sample-app", lookback: "15m", limit: 50, project_bound: true },
          data: { supported: true, errors: [] },
        })),
      });
    });
    await page.getByRole("link", { name: "Errors" }).click();
    await expect(page.getByText("No recent errors observed.")).toBeVisible();
  });

  test("schema-valid no_matching is a warning, not an error", async ({ page }) => {
    await page.route("**/api/context*", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(envelope("context", {
          backends: [
            { name: "logs", status: "no_matching" },
            { name: "metrics", status: "no_matching_data" },
          ],
          data: { supported: true, logs: [], metrics: [] },
        })),
      });
    });
    await page.goto(bootstrapURL);
    await expect(page.locator("#overview-backends .status-card.warning")).toHaveCount(2);
    await expect(page.locator("#query-state")).toHaveClass(/status-ok/);
  });

  test("errors request failure stays in a table row", async ({ page }) => {
    await page.route("**/api/errors*", async (route) => {
      await route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "backend_unavailable" }) });
    });
    await page.goto(bootstrapURL);
    await page.getByRole("link", { name: "Errors" }).click();
    await expect(page.locator("#errors-table > tr > td")).toHaveAttribute("colspan", "4");
    await expect(page.locator("#errors-table > div")).toHaveCount(0);
    await expect(page.locator("#query-state")).toHaveClass(/status-error/);
    await expect(page.locator("#errors-table")).toContainText("Unable to load errors: backend_unavailable");
  });

  test("errors network timeout stays visible in a table row", async ({ page }) => {
    await page.route("**/api/errors*", async (route) => {
      await route.abort("timedout");
    });
    await page.goto(bootstrapURL);
    await page.getByRole("link", { name: "Errors" }).click();
    await expect(page.locator("#errors-table > tr > td")).toHaveAttribute("colspan", "4");
    await expect(page.locator("#errors-table > div")).toHaveCount(0);
    await expect(page.locator("#query-state")).toHaveClass(/status-error/);
    await expect(page.locator("#errors-table")).toContainText("Unable to load errors");
  });

  test("responsive narrow viewport keeps the console usable", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto(bootstrapURL);
    await expect(page.getByRole("heading", { name: "System signals, without the noise." })).toBeVisible();
    const dimensions = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      content: document.documentElement.scrollWidth,
    }));
    expect(dimensions.content).toBeLessThanOrEqual(dimensions.viewport + 1);
    await expect(page.locator("#lookback-select")).toBeVisible();
  });
});
