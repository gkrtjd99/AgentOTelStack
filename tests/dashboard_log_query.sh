#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_dir/dashboards/local-observability.json"

query="$(python3 - "$dashboard" <<'PY'
import json, sys
dashboard = json.load(open(sys.argv[1]))
for panel in dashboard["panels"]:
    if panel.get("title") == "Recent Error Logs":
        print(panel["targets"][0]["expr"])
        break
else:
    raise SystemExit("Recent Error Logs panel missing")
PY
)"

expected='_time:15m service.name:"$service" severity_text:"error"'
[[ "$query" == "$expected" ]] || {
  echo "unexpected VictoriaLogs query: $query" >&2
  exit 1
}
[[ "$query" != *'service.name:$service'* ]] || exit 1
[[ "$query" != *'severity_text:error'* ]] || exit 1
echo "dashboard VictoriaLogs query grammar passed"
