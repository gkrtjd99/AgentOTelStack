# Changelog

## 2.0.0 — 2026-08-12

### Highlights

- Host-facing telemetry now goes through the authenticated Gateway: OTLP/HTTP
  ingest on `127.0.0.1:4318` and read-only query API on `127.0.0.1:17777`.
- Versioned, clone-independent installs support `current`/`previous` pointers
  and rollback; credentials are generated with restrictive permissions.
- MCP exposes exactly three read-only tools: `agentotel_context`,
  `agentotel_correlate`, and `agentotel_services`.
- Collector queues, retry/batching, redaction, and low-cardinality controls are
  included, with Pino logs bridged into OpenTelemetry.

### Breaking changes / migration

- Apps must stop connecting directly to the collector or Victoria backends and
  send OTLP with the Gateway ingest token. Query scripts and MCP use the query
  token through the Gateway.
- Install the versioned runtime, then initialize and start it:
  `make install VERSION=2.0.0`, `make setup`, `make doctor`, `make up`.
  `obs runtime rollback` returns to the previous installed version.
- Run `make setup` before `make up`. `migration_required` legacy or mismatched
  volumes are never automatically deleted or relabeled; use `make migrate` to
  back up, copy, and verify data manually.
- `make clean` preserves volumes. Destructive cleanup is only
  `obs reset --all --confirm`, guarded by TTY, UUID, Compose-project, and exact
  volume checks.

### Security and supply chain

- Grafana includes the pinned VictoriaLogs datasource plugin v0.31.0 with the
  exact SHA-256 checksum
  `6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b`.
  Local authentication is enabled.
- Narrow upstream Grafana CVE waivers are tracked in
  [`security/grafana-trivy-waivers.json`](security/grafana-trivy-waivers.json)
  and expire 2026-09-11.

### Validation

Executed validation completed with `make ci-local`: 13 PASS, 0 FAIL, 0 SKIP.
Gateway and MCP gofmt checks were clean, and Gateway/MCP `go test` plus
`go test -race` passed. The isolated live integration also passed wrong-token
`401` and valid-token `200` checks, stored error-trace discovery, complete
three-backend correlation, schema/API version `1.0`, a controlled VictoriaLogs
outage with a partial response, and restart recovery. The release-version
check and `git diff --check` passed as well.

The GitHub-hosted full CI and supply-chain jobs were still pending after push;
they are not represented as passed here.

### Known limitations

- This remains a same-user local Docker stack; remote exposure needs a separate
  TLS/authentication boundary.
- `project.id` is provenance/filter metadata, not an authentication boundary;
  a same-user process with local credentials or Docker access can read or alter
  the stack.
- Legacy volume migration is intentionally manual. Grafana is optional.
- README verification figures are historical and are not current v2.0.0
  runtime evidence.

### 한국어 요약

인증 Gateway(4318 ingest/17777 query), `make install VERSION=2.0.0` 기반
버전 설치·롤백, 세 개의 읽기 전용 MCP 도구, 안전한 storage/reset 및 수동
migration 보호를 도입했습니다. VictoriaLogs plugin v0.31.0은 지정된 SHA-256
checksum으로 고정되며 Grafana CVE waiver는 2026-09-11에 만료됩니다.
로컬 검증은 `make ci-local`에서 13 PASS/0 FAIL/0 SKIP을 기록했고, Gateway/MCP
gofmt·go test·race test, release version check, live 전체 correlation 및
VictoriaLogs 장애·복구 검증도 완료했습니다. GitHub-hosted full CI/supply-chain
job은 push 후 pending 상태이며 통과로 주장하지 않습니다. `project.id`는 인증
경계가 아니며 README의 기존 수치는 현재 v2.0.0 실행 증거가 아닙니다.
