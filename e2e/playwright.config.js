// @ts-check
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const playwrightEntry = require.resolve("playwright");
const { isWorkerProcess } = require(
  path.join(path.dirname(playwrightEntry), "lib", "globals.js"),
);
const { defineConfig } = require("@playwright/test");

const mode = process.env.AGENTOTEL_E2E_MODE;
const expectedDashboardStatus = mode === "all" || mode === "dashboard" ? "ready" : "not_required";
const lifecycleRoot = path.resolve(__dirname, "..");

const launcherPaths = {
  "run-e2e": path.join(lifecycleRoot, "scripts", "run-e2e.sh"),
  "test-ci-integration": path.join(
    lifecycleRoot,
    "scripts",
    "test-ci-integration.sh",
  ),
};

function processInfo(pid) {
  const output = execFileSync(
    "ps",
    ["-ww", "-o", "pid=,ppid=,command=", "-p", String(pid)],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();
  const match = output.match(/^(\d+)\s+(\d+)\s+(.*)$/);
  if (!match) {
    throw new Error(`Unable to inspect process ${pid}`);
  }
  return {
    pid: Number(match[1]),
    ppid: Number(match[2]),
    command: match[3],
  };
}

function processAncestry() {
  const ancestry = [];
  let pid = process.pid;
  for (let depth = 0; depth < 64 && pid > 0; depth += 1) {
    let info;
    try {
      info = processInfo(pid);
    } catch (error) {
      throw new Error(`Unable to inspect E2E process ancestry: ${error.message}`);
    }
    ancestry.push(info);
    if (info.ppid <= 0 || info.ppid === info.pid) {
      break;
    }
    pid = info.ppid;
  }
  return ancestry;
}

function commandContainsPath(command, expectedPath) {
  return command.split(/\s+/).some((token) => {
    const candidate = token.replace(/^['"]|['"]$/g, "");
    if (!candidate || candidate.startsWith("-")) {
      return false;
    }
    const resolved = path.resolve(lifecycleRoot, candidate);
    return resolved === path.resolve(expectedPath);
  });
}

function validateLauncher(readiness) {
  if (
    !Number.isInteger(readiness.launcher_pid) ||
    readiness.launcher_pid <= 0 ||
    !Object.prototype.hasOwnProperty.call(launcherPaths, readiness.launcher_kind)
  ) {
    throw new Error("Invalid lifecycle launcher metadata");
  }
  const launcher = processAncestry().find(
    (info) => info.pid === readiness.launcher_pid,
  );
  if (!launcher) {
    throw new Error("E2E readiness capability launcher is not an ancestor");
  }
  if (!commandContainsPath(launcher.command, launcherPaths[readiness.launcher_kind])) {
    throw new Error("E2E readiness capability launcher command is not approved");
  }
}

function validateReadiness(readiness) {
  if (
    !readiness ||
    typeof readiness !== "object" ||
    readiness.version !== 2 ||
    readiness.kind !== "agentotel.e2e-ready.v2" ||
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
  validateLauncher(readiness);
}

// Playwright worker processes set this private process-local flag before
// loading tests. Do not infer the main/worker distinction from environment
// variables: callers can set TEST_WORKER_INDEX before invoking this config.
// The main/loader process must redeem the inherited lifecycle capability;
// workers are created only after that process has validated it.
if (!isWorkerProcess()) {
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
