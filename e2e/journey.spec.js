// @ts-check
// UI journey: drives the sample-app UI in a real browser so the full path
// (browser -> express -> business logic) is captured as traces/logs/metrics.
// Closes the feedback loop in the diagram: e2e runner -> UI journey -> app.
const { test, expect } = require("@playwright/test");

test("happy path: process an order then checkout", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "sample-app" })).toBeVisible();

  await page.getByRole("button", { name: "Process order" }).click();
  await expect(page.locator("#out")).toContainText("→ 200", { timeout: 5000 });

  await page.getByRole("button", { name: "Checkout" }).click();
  await expect(page.locator("#out")).toContainText("→", { timeout: 5000 });
});

test("error path: forced failure surfaces a 500", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Force failure" }).click();
  await expect(page.locator("#out")).toContainText("→ 500", { timeout: 5000 });
});
