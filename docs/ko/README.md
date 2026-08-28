# 문서 색인

[English](../README.md) · [한국어](./README.md)

AgentOTelStack은 루트 [`README.md`](../../README.md)를 간결하게 유지합니다. 이 디렉터리에는 설치, 운영, 쿼리, 개발 및 로컬 보안 경계에 대한 상세한 한국어 권위 문서가 있습니다.

## 먼저 읽기

| 필요한 내용 | 권위 문서 |
| --- | --- |
| 태그가 지정된 clone-independent 런타임 설치 | [`AGENT_SETUP.md`](./AGENT_SETUP.md) |
| 스토리지 시작, 중지, 점검, 초기화, 교체 또는 마이그레이션 | [`OPERATIONS.md`](./OPERATIONS.md) |
| 제한된 context, errors, services 및 correlation 쿼리 | [`QUERY.md`](./QUERY.md) |
| 애플리케이션 또는 MCP 클라이언트를 Gateway에 연결 | [`CONNECT.md`](./CONNECT.md) |
| 6개 서비스 topology와 네트워크 경계 이해 | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| 브라우저 Dashboard 또는 터미널 overview 사용 | [`DASHBOARD.md`](./DASHBOARD.md) |
| 소스 checkout에서 작업하고 테스트 실행 | [`DEVELOPMENT.md`](./DEVELOPMENT.md) |
| credential, project, port, health 또는 no data 진단 | [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) |
| immutable source release 준비 | [`RELEASING.md`](./RELEASING.md) |
| 포함된 sample application 교체 | [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md) |

## 공개 계약 및 경계

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — 인증된 Gateway ingest/query 경계, Collector fan-out, 내부 store, Compose profile, network 및 project scope.
- [`CONNECT.md`](./CONNECT.md) — `obs run` 경로, 수동 OTLP 환경 변수, 언어별 예시 및 읽기 전용 MCP adapter.
- [`DASHBOARD.md`](./DASHBOARD.md) — 유일한 브라우저 UI, one-time client credential, 제한된 route 및 Make 전용 브라우저 lifecycle.
- [`SECURITY.md`](./SECURITY.md) — 동일 사용자 threat model, credential 역할, redaction, supply-chain 검사 및 원격 노출 경고.
- [`JSON_CONTRACT.md`](./JSON_CONTRACT.md) — Gateway envelope 및 backend status 의미.
- [`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md) — 관측된 응답이 전체 ingest의 증명이 아니라 제한된 증거인 이유.

Agent contract는 이 공개 매뉴얼과 의도적으로 분리되어 있습니다. [`../../AGENTS.md`](../../AGENTS.md)는 machine-oriented observe → reason → change → re-run 안내서이며, [`../../CLAUDE.md`](../../CLAUDE.md)는 해당 repository symlink입니다. split-ready Dashboard module에는 [`../../src/dashboard/README.md`](../../src/dashboard/README.md)에 자체 build 및 API 참고 사항이 있습니다.

## 지원되는 command 경계

설치된 운영에는 global `obs` launcher를 사용합니다. checkout 전용 개발에는 `make` 또는 명시적인 `AGENTOTEL_DEV_MODE=1 ./bin/obs ...` prefix를 사용합니다. Query helper는 항상 인증된 Gateway를 사용하며, 이 문서는 raw LogQL, PromQL, Jaeger, Victoria 또는 Collector endpoint를 제공하지 않습니다.
