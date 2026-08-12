# Changelog

## 2.0.1 — 2026-08-13

- Corrected Compose project identity resolution so demo workloads use the
  current workspace UUIDv4 and cannot silently reuse a stale or shared scope.
- Improved query/runtime correctness with authenticated Gateway-only access,
  bounded parallel backend queries, safer response projection, and runtime-
  specific image/version selection across rollback.
- Hardened credentials, volume identity checks, storage diagnostics, and MCP
  build/version plumbing; added targeted release, documentation, and runtime
  contract coverage.

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

The full local CI-equivalent gate set passed, including Gateway/MCP gofmt,
`go test` and `go test -race`, project/credential tests, atomic install/symlink
tests, release-version and `git diff --check` validation. Gitleaks passed for
the full history and source snapshot; fresh app and Gateway Trivy scans found
zero HIGH/CRITICAL findings; the exact Grafana waiver, pinned backend health
images on amd64/arm64, and related supply-chain checks passed.

Isolated live integration passed wrong-token `401` and valid-token `200`,
stored error-trace discovery, complete three-backend correlation with
`error=true`, schema/API version `1.0`, and a controlled VictoriaLogs outage
with partial response followed by restart recovery.

The previous hosted push failed; these corrections address that failure.
GitHub-hosted CI and supply-chain checks for PR #1 are the publication gate;
their final status is recorded in the PR checks, and this changelog does not
pre-assert that outcome.

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
로컬 CI-equivalent gate 전체를 통과했고 Gateway/MCP 포맷·테스트·race,
project/credential 및 atomic install/symlink 검증, 전체 이력·소스 Gitleaks,
app/Gateway Trivy HIGH/CRITICAL 0건, Grafana waiver, amd64/arm64 backend health,
인증과 `error=true`를 포함한 3-backend correlation 및 VictoriaLogs 장애·복구를
확인했습니다. 이전 hosted push는 실패했으며 이 수정이 이를 보완합니다. PR #1의
GitHub-hosted CI/supply-chain checks가 publication gate이고 최종 상태는 PR checks에
기록되며, 이 changelog는 그 결과를 선행 주장하지 않습니다. `project.id`는 인증
경계가 아니며 README의 기존 수치는 현재 v2.0.0 실행 증거가 아닙니다.
