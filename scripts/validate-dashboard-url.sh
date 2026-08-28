#!/usr/bin/env bash
# Validate and normalize a Dashboard client URL before sending credentials.
set -Eeuo pipefail

url="${1:-}"
expected_port="${2:-}"
[[ -n "$url" ]] || { echo 'dashboard URL is required' >&2; exit 2; }
[[ -z "$expected_port" || "$expected_port" =~ ^[0-9]+$ ]] || {
  echo 'expected Dashboard port must be decimal' >&2
  exit 2
}

python3 - "$url" "$expected_port" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

value, expected = sys.argv[1:]
try:
    parsed = urlsplit(value)
except ValueError as exc:
    raise SystemExit(f"invalid Dashboard URL: {exc}")

if parsed.scheme not in ("http", "https"):
    raise SystemExit("Dashboard URL must use http or https")
if not parsed.netloc or parsed.username is not None or parsed.password is not None:
    raise SystemExit("Dashboard URL must contain only a loopback host and port")
if parsed.query or parsed.fragment or parsed.path not in ("", "/"):
    raise SystemExit("Dashboard URL must not contain a path, query, or fragment")
try:
    host = parsed.hostname
    port = parsed.port
except ValueError as exc:
    raise SystemExit(f"invalid Dashboard URL: {exc}")
if host is None or port is None or not 1 <= port <= 65535:
    raise SystemExit("Dashboard URL must include a valid TCP port")
host = host.lower()
allowed = host == "localhost"
try:
    address = ipaddress.ip_address(host)
except ValueError:
    address = None
if address is not None:
    allowed = (address.version == 4 and address in ipaddress.ip_network("127.0.0.0/8")) or address == ipaddress.IPv6Address("::1")
if not allowed:
    raise SystemExit("Dashboard URL host must be localhost or a loopback literal")
if expected and port != int(expected):
    raise SystemExit(f"Dashboard URL port {port} does not match expected port {expected}")

# Preserve the caller's scheme/host spelling while removing only a harmless
# trailing slash. The validated URL always contains an explicit port.
print(value[:-1] if value.endswith("/") else value)
PY
