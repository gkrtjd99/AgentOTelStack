#!/usr/bin/env bash
# Source-only browser lifecycle library. The Make-managed lifecycle scripts and
# the command-contract fixture source this file and call run_browser_e2e().
if (( ${#BASH_SOURCE[@]} < 2 )); then
  echo 'run-browser-e2e: internal lifecycle helper must be sourced, not executed directly' >&2
  exit 1
fi

run_browser_e2e() {
  local mode="${1:-}" ready_proof_file="${2:-}" root e2e_dir caller_script helper_script caller_base caller_dir
  local runtime_config test_rc=0
  local lock_before lock_after playwright_cli expected_bootstrap_url
  local npm_bin node_bin python3_bin
  local -a browser_args test_args

  case "$mode" in
    all|app|dashboard) ;;
    *) echo "run-browser-e2e: usage: run_browser_e2e {all|app|dashboard} proof-file" >&2; return 2 ;;
  esac
  [[ -n "$ready_proof_file" && -f "$ready_proof_file" && ! -L "$ready_proof_file" ]] || {
    echo 'run-browser-e2e: missing lifecycle readiness proof file' >&2
    return 1
  }

  # Resolve the helper and caller from Bash's source stack.  Do not invoke
  # caller-controlled dirname, basename, or other shell functions while making
  # the lifecycle authorization decision.
  helper_script="${BASH_SOURCE[0]:-}"
  case "$helper_script" in
    */scripts/run-browser-e2e.sh) root="${helper_script%/scripts/run-browser-e2e.sh}" ;;
    *)
      echo 'run-browser-e2e: helper source path is not repository-owned' >&2
      return 1
      ;;
  esac
  if ! root="$(CDPATH=; builtin cd -- "$root" && builtin pwd -P)"; then
    echo 'run-browser-e2e: unable to resolve repository root' >&2
    return 1
  fi
  e2e_dir="$root/e2e"
  caller_script="${BASH_SOURCE[1]:-}"
  case "$caller_script" in
    */*)
      caller_base="${caller_script##*/}"
      caller_dir="${caller_script%/*}"
      if ! caller_dir="$(CDPATH=; builtin cd -- "$caller_dir" && builtin pwd -P)"; then
        echo 'run-browser-e2e: unable to resolve lifecycle caller' >&2
        return 1
      fi
      caller_script="$caller_dir/$caller_base"
      ;;
    *)
      caller_script=''
      ;;
  esac
  case "$caller_script" in
    "$root/scripts/run-e2e.sh"|"$root/scripts/test-ci-integration.sh"|"$root/tests/runtime/e2e_command_contract.sh") ;;
    *)
      echo 'run-browser-e2e: lifecycle helper was called by an unapproved source' >&2
      return 1
      ;;
  esac

  if ! npm_bin="$(builtin type -P npm 2>/dev/null)" || [[ ! -x "$npm_bin" ]]; then
    echo 'run-browser-e2e: npm is unavailable' >&2
    return 1
  fi
  if ! node_bin="$(builtin type -P node 2>/dev/null)" || [[ ! -x "$node_bin" ]]; then
    echo 'run-browser-e2e: node is unavailable' >&2
    return 1
  fi
  if ! python3_bin="$(builtin type -P python3 2>/dev/null)" || [[ ! -x "$python3_bin" ]]; then
    echo 'run-browser-e2e: python3 is unavailable' >&2
    return 1
  fi
  [[ -f "$e2e_dir/package-lock.json" ]] || { echo 'run-browser-e2e: package-lock.json is missing' >&2; return 1; }

  # This proof carries completed lifecycle state only. Caller identity is bound
  # by the real Bash source stack above; it is never inferred from ps or argv.
  if ! "$python3_bin" - "$ready_proof_file" "$mode" "${AGENTOTEL_PROJECT_ID:-}" "${COMPOSE_PROJECT_NAME:-}" <<'PY'
import json
import pathlib
import re
import sys
import time

proof_path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
expected_project_id = sys.argv[3]
expected_compose_project = sys.argv[4]
try:
    proof = json.loads(proof_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"run-browser-e2e: invalid lifecycle readiness proof: {exc}")

expected_dashboard_status = "ready" if mode in ("all", "dashboard") else "not_required"
required = {
    "version": 3,
    "kind": "agentotel.e2e-ready.v3",
    "mode": mode,
    "dashboard_status": expected_dashboard_status,
}
for key, value in required.items():
    if proof.get(key) != value:
        raise SystemExit(f"run-browser-e2e: readiness proof has invalid {key}")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", proof.get("project_id", "")):
    raise SystemExit("run-browser-e2e: readiness proof has invalid project UUID")
if expected_project_id and proof["project_id"] != expected_project_id:
    raise SystemExit("run-browser-e2e: readiness proof project UUID does not match lifecycle")
if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", proof.get("compose_project", "")):
    raise SystemExit("run-browser-e2e: readiness proof has invalid Compose project")
if expected_compose_project and proof["compose_project"] != expected_compose_project:
    raise SystemExit("run-browser-e2e: readiness proof Compose project does not match lifecycle")
if not re.fullmatch(r"[0-9a-f]{32}", proof.get("nonce", "")):
    raise SystemExit("run-browser-e2e: readiness proof has invalid nonce")
issued_at = proof.get("issued_at")
if isinstance(issued_at, bool) or not isinstance(issued_at, int) or abs(time.time() - issued_at) > 600:
    raise SystemExit("run-browser-e2e: lifecycle readiness proof is stale")
PY
  then
    return 1
  fi

  # Do not let caller-supplied worker markers or legacy readiness markers alter
  # the lockfile install or the Playwright command.
  unset TEST_WORKER_INDEX TEST_PARALLEL_INDEX AGENTOTEL_E2E_READY_VERIFIED

  if ! lock_before="$(shasum -a 256 "$e2e_dir/package-lock.json" | awk '{print $1}')"; then
    echo 'run-browser-e2e: unable to hash e2e/package-lock.json before install' >&2
    return 1
  fi
  if ! (
    cd "$e2e_dir" || exit 1
    "$npm_bin" ci --ignore-scripts --no-audit
  ); then
    echo 'run-browser-e2e: npm ci failed' >&2
    return 1
  fi
  if ! lock_after="$(shasum -a 256 "$e2e_dir/package-lock.json" | awk '{print $1}')"; then
    echo 'run-browser-e2e: unable to hash e2e/package-lock.json after install' >&2
    return 1
  fi
  [[ "$lock_before" == "$lock_after" ]] || {
    echo 'run-browser-e2e: npm ci mutated e2e/package-lock.json' >&2
    return 1
  }
  playwright_cli="$e2e_dir/node_modules/playwright/cli.js"
  [[ -r "$playwright_cli" ]] || {
    echo 'run-browser-e2e: npm ci did not install the Playwright CLI' >&2
    return 1
  }

  browser_args=(install chromium)
  if [[ "${CI:-0}" == 1 || "${PLAYWRIGHT_INSTALL_WITH_DEPS:-0}" == 1 ]]; then
    browser_args=(install --with-deps chromium)
  fi
  if ! (
    cd "$e2e_dir" || exit 1
    "$node_bin" "$playwright_cli" "${browser_args[@]}"
  ); then
    echo 'run-browser-e2e: Playwright browser installation failed' >&2
    return 1
  fi

  export AGENTOTEL_E2E_MODE="$mode"
  case "$mode" in
    all) test_args=(test) ;;
    app) test_args=(test journey.spec.js) ;;
    dashboard) test_args=(test dashboard.spec.js) ;;
  esac

  if [[ "$mode" == dashboard || "$mode" == all ]]; then
    export DASHBOARD_E2E_LIVE=1
    if [[ ! "${DASHBOARD_E2E_AUTH_TOKEN:-}" =~ ^[0-9a-f]{64}$ ]]; then
      echo 'run-browser-e2e: live Dashboard E2E requires a generated client token' >&2
      return 1
    fi
    if ! DASHBOARD_URL="$("$root/scripts/validate-dashboard-url.sh" "${DASHBOARD_URL:-}" "${DASHBOARD_HOST_PORT:-3001}" 2>&1)"; then
      echo "run-browser-e2e: $DASHBOARD_URL" >&2
      return 1
    fi
    export DASHBOARD_URL
    expected_bootstrap_url="${DASHBOARD_URL}/#token=${DASHBOARD_E2E_AUTH_TOKEN}"
    [[ "${DASHBOARD_BOOTSTRAP_URL:-}" == "$expected_bootstrap_url" ]] || {
      echo 'run-browser-e2e: live Dashboard E2E requires a matching bootstrap URL' >&2
      return 1
    }
  fi

  # The repository config is deliberately a rejecting default. Generate the
  # private runtime config only after lifecycle validation and dependency setup.
  if ! runtime_config="$(mktemp "$e2e_dir/.playwright-lifecycle.XXXXXX")"; then
    echo 'run-browser-e2e: unable to create private Playwright config' >&2
    return 1
  fi
  chmod 600 "$runtime_config" || {
    rm -f "$runtime_config"
    echo 'run-browser-e2e: unable to protect private Playwright config' >&2
    return 1
  }
  if ! "$python3_bin" - "$runtime_config" "$e2e_dir" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
test_dir = sys.argv[2]
config_path.write_text(
    "// Generated only by the Make-managed browser lifecycle.\n"
    'const { defineConfig } = require("@playwright/test");\n'
    "module.exports = defineConfig({\n"
    f"  testDir: {json.dumps(test_dir)},\n"
    "  timeout: 30_000,\n"
    "  use: {\n"
    '    baseURL: process.env.APP_URL || "http://localhost:3000",\n'
    "    headless: true,\n"
    "  },\n"
    '  reporter: [["list"]],\n'
    "});\n",
    encoding="utf-8",
)
PY
  then
    rm -f "$runtime_config"
    return 1
  fi
  case "$mode" in
    all) test_args+=(--config "$runtime_config") ;;
    app) test_args=(test --config "$runtime_config" journey.spec.js) ;;
    dashboard) test_args=(test --config "$runtime_config" dashboard.spec.js) ;;
  esac
  (
    cd "$e2e_dir" || exit 1
    "$node_bin" "$playwright_cli" "${test_args[@]}"
  ) || test_rc=$?
  rm -f "$runtime_config"
  return "$test_rc"
}
