"""Canonical source-release path policy shared by the builder and verifier."""
import fnmatch
import re

RETIRED_PREFIXES = (
    "src/grafana",
    "src/dashboards",
    "tests/dashboard_log_query.sh",
    "scripts/verify-trivy-waivers.sh",
    "security/grafana-trivy-waivers.json",
    "security/grafana-trivy-waivers.yaml",
    "security/test-trivy-waivers.sh",
)

GENERATED_COMPONENTS = {
    ".agentotel",
    ".git",
    ".cache",
    ".trivy-cache",
    ".npm",
    ".yarn",
    ".pnpm-store",
    ".nyc_output",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    "__pycache__",
    "node_modules",
    "artifacts",
    "coverage",
    "test-results",
    "playwright-report",
    "playwright-artifacts",
    "build",
    "dist",
    "tmp",
}
GENERATED_SUFFIXES = (
    ".log",
    ".out",
    ".prof",
    ".test",
    ".coverage",
    ".coverprofile",
    ".tmp",
)
GENERATED_BASENAMES = {
    ".DS_Store",
    ".eslintcache",
    ".stylelintcache",
    "manifest.sha256",
}

SECRET_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".crt", ".cer")


def retired_path(path: str) -> bool:
    return any(path == item or path.startswith(item + "/") for item in RETIRED_PREFIXES)


def dashboard_artifact_path(path: str) -> bool:
    return path == "src/dashboard/dashboard" or path.startswith("src/dashboard/dashboard/")


def generated_path(path: str) -> bool:
    parts = path.split("/")
    base = parts[-1]
    if dashboard_artifact_path(path):
        return True
    if any(part in GENERATED_COMPONENTS for part in parts):
        return True
    if (path != "bin" and "bin" in parts and path != "bin/obs") or path == "src/mcp/mcp":
        return True
    if path.startswith("bin/agentotel-mcp"):
        return True
    if base in GENERATED_BASENAMES or base.startswith("._"):
        return True
    if base.endswith(GENERATED_SUFFIXES):
        return True
    if fnmatch.fnmatch(base, "*.install.tmp.*"):
        return True
    if re.fullmatch(r"(?:current|previous)\.tmp\.[^/]+", base):
        return True
    if re.fullmatch(r"manifest\.sha256\.(?:raw|tmp)\.[^/]+", base):
        return True
    if base.startswith(".install.tmp."):
        return True
    return False


def secret_path(path: str) -> bool:
    parts = path.split("/")
    base = parts[-1]
    if base == ".env.example" or base.endswith("/.env.example"):
        return False
    if base == ".env" or base.startswith(".env."):
        return True
    if base in {"credentials", "secrets", "id_rsa", "id_ed25519"}:
        return True
    if base.startswith(("id_rsa.", "id_ed25519.")):
        return True
    if any(part in {"credentials", "secrets", ".aws", ".kube"} for part in parts):
        return True
    return base.endswith(SECRET_SUFFIXES)


def classify(path: str):
    """Return a stable policy class used for diagnostics, or None."""
    if retired_path(path):
        return "retired"
    if dashboard_artifact_path(path):
        return "dashboard-artifact"
    if secret_path(path):
        return "secret"
    if generated_path(path):
        return "generated"
    return None


def diagnostic(path: str, tracked: bool = False):
    kind = classify(path)
    if kind == "retired":
        return f"retired dashboard path is forbidden: {path}"
    if kind == "dashboard-artifact":
        return f"dashboard build artifact is forbidden: {path}"
    if kind == "secret":
        if tracked:
            return f"tracked secret-like path is forbidden: {path}"
        return f"secret-like path is forbidden: {path}"
    if kind == "generated":
        if tracked:
            return f"tracked generated output is forbidden: {path}"
        return f"forbidden generated output is present: {path}"
    return None
