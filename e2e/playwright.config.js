// @ts-check
const { defineConfig } = require("@playwright/test");

if (process.env.AGENTOTEL_E2E_STACK_READY !== "1") {
  throw new Error(
    "Direct npm E2E invocation is unsupported: run `make e2e`, `make e2e-app`, or `make e2e-dashboard`; those Make targets start and await the required stack before Playwright runs.",
  );
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
