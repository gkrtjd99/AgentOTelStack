#!/usr/bin/env bash
set -euo pipefail

# Bounded A/B benchmark for the collector batch processor. It uses a temporary
# collector config and a local fake OTLP/HTTP exporter; no stack volumes are
# touched. The request payload is deliberately one sparse log record, so the
# batch timeout (rather than send_batch_size) determines export latency.
cd "$(dirname "$0")/.."

image="${OTEL_BENCH_IMAGE:-dev-observability/otel-collector:v0.158.0-health}"
work="$(mktemp -d /tmp/agentotel-batch-bench.XXXXXX)"
fake_port="${OTEL_BENCH_FAKE_PORT:-18080}"
recv_port="${OTEL_BENCH_RECEIVER_PORT:-18081}"
fake_pid=''
collector='agentotel-batch-bench-collector'
trap 'set +e; [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null || true; docker rm -f "$collector" >/dev/null 2>&1 || true' EXIT

cat >"$work/fake_exporter.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, os, time
out = os.environ["OUT"]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0")); self.rfile.read(n)
        with open(out, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ms": time.time_ns() // 1_000_000, "path": self.path}) + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *_): pass
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY

cat >"$work/payload.json" <<'JSON'
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"batch-bench"}}]},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"1700000000000000000","severityText":"ERROR","body":{"stringValue":"batch benchmark"}}]}]}]}
JSON

cat >"$work/config.yaml" <<EOF
receivers:
  otlp:
    protocols:
      http: {endpoint: 0.0.0.0:${recv_port}}
processors:
  batch:
    timeout: __BATCH_TIMEOUT__
    send_batch_size: 1024
    send_batch_max_size: 1024
exporters:
  otlp_http/fake:
    logs_endpoint: http://host.docker.internal:${fake_port}/v1/logs
    tls: {insecure: true}
    timeout: 2s
service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp_http/fake]
EOF

OUT="$work/exports.jsonl" PORT="$fake_port" python3 -u "$work/fake_exporter.py" >"$work/fake.log" 2>&1 & fake_pid=$!
sleep 0.2

run_case() {
  local timeout="$1"; : >"$work/exports.jsonl"
  sed "s/__BATCH_TIMEOUT__/$timeout/" "$work/config.yaml" >"$work/config-$timeout.yaml"
  docker rm -f "$collector" >/dev/null 2>&1 || true
  docker run -d --name "$collector" --add-host=host.docker.internal:host-gateway \
    -p "${recv_port}:${recv_port}" -e BATCH_TIMEOUT="$timeout" \
    -v "$work/config-$timeout.yaml:/etc/otelcol/config.yaml:ro" "$image" \
    --config=/etc/otelcol/config.yaml >/dev/null
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:${recv_port}" >/dev/null 2>&1 && break; sleep 0.1; done
  for sample in 1 2 3; do
    before=$(python3 -c 'import time; print(time.time_ns()//1000000)')
    curl -fsS -H 'Content-Type: application/json' --data-binary @"$work/payload.json" "http://127.0.0.1:${recv_port}/v1/logs" >/dev/null
    for _ in $(seq 1 100); do
      if [ "$(wc -l <"$work/exports.jsonl")" -ge "$sample" ]; then break; fi
      sleep 0.05
    done
    after=$(python3 -c 'import time; print(time.time_ns()//1000000)')
    export_ms=$(tail -1 "$work/exports.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ms"])')
    echo "case=$timeout sample=$sample receive_to_export_ms=$((export_ms-before)) request_to_response_ms=$((after-before))"
  done
  docker logs "$collector" 2>&1 | rg -i 'error|drop|failed|queue' || true
}

run_case 5s
run_case 1s
