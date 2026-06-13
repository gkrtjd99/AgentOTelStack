# agent-otel-stack

> **[English](#english) · [한국어](#한국어)**

A local observability stack for AI coding agents (**Claude Code · Codex ·
OpenCode …**) and humans. One shared, Docker-based backend for
**logs · metrics · traces**, with an **observe → reason → change → re-run**
feedback loop driven by plain `curl` query tools. No SDK needed to *read*
telemetry — any agent reads `AGENTS.md` and uses the same four scripts.

---

## English

A self-contained observability backend you run once on your machine. Any number
of your own apps point at it over OTLP (`http://localhost:4318`); everything
lands in the same stores and is queried side by side. The agent (or you) reads
telemetry back through `./obs/*.sh`.

### Architecture

```
app (OTLP) ──> OpenTelemetry Collector ──fanout──> VictoriaLogs    (LogQL)
                                                ├─> VictoriaMetrics  (PromQL)
                                                └─> VictoriaTraces   (Jaeger query)
                                                       ▲
                          ./obs/*.sh  query tools  +  AGENTS.md  ┘   ← any agent
```

- The **OpenTelemetry Collector** is the single fan-out point (not Vector — as of
  2026 Vector's OTLP source can't ingest metrics or export logs/metrics over OTLP).
- **VictoriaTraces has no native TraceQL** (2026) — it speaks the **Jaeger query
  API**. That's why `obs/traces.sh` uses Jaeger-style subcommands.

### The feedback loop

```
  app ──OTLP──> otel-collector ──fanout──> VictoriaLogs    (LogQL)
                                         ├─> VictoriaMetrics (PromQL)
                                         └─> VictoriaTraces  (Jaeger query)
                                                 │
           ┌─────────────────────────────────────┘  ./obs/*.sh  (query · correlate)
           ▼
  ┌──────────────────────────────────┐
  │  coding agent (any)              │  ← Claude Code · Codex · OpenCode · …
  │  observe → correlate → reason    │     (CLAUDE.md is a symlink to AGENTS.md,
  │                                  │      so every agent reads one source)
  └────────────────┬─────────────────┘
                   │  edit app/ · docker compose up -d --build app
                   ▼
             ┌───────────┐
             │  codebase │
             └─────┬─────┘
                   │  re-run
                   ▼
       ┌──────────────────────┐
       │ workload/run.sh      │ ──▶  e2e/ (Playwright UI journey)
       └──────────┬───────────┘
                  │  new telemetry → observe again (loop closes)
                  └──────────────────────▶ obs tools
```

### Why

What an agent (or a human) editing code lacks most is **fact-based feedback on
whether a change actually worked**. Logs alone are fragmentary; metrics alone
tell you *what* broke but not *where* or *why*. This stack:

- **Unifies the three signals** in one backend, so they connect to each other.
- **Pivots across signals on `trace_id`** — "error rate spiked" (metric) →
  "this request failed" (log) → "this span in this code path returned 500"
  (trace), all at once. (`./obs/correlate.sh`)
- **Needs no SDK to read** — just four `curl` wrappers (`./obs/*.sh`). Any agent
  reads `AGENTS.md` and runs the same loop with the same tools.
- **Is shared by every local project once it's up** — give each app a different
  `OTEL_SERVICE_NAME` and they all report into the same backend and are queried
  side by side.

### What you get

With this stack attached you can answer, in **numbers** (see [Verified](#verified-2026-06-09)):

- **Error rate** — `sum(...{outcome="error"}) / sum(...)` → e.g. 18.7%
- **Latency distribution** — `histogram_quantile(0.95, ...)` → e.g. p95 4.75s
- **Failure localization** — from a failed request's trace, instantly see which
  span (`GET /api/checkout`) carried `http.status_code=500`
- **Before/after comparison** — after a fix, re-run the same workload and verify
  the error rate / latency actually dropped

So instead of "I think I fixed it", you say **"error rate 18.7% → 0%"**.

### Verified (2026-06-09)

> Final verification date **2026-06-09**. Below are actual run results, not claims.

Booted the full stack with `make demo`, drove load with `./workload/run.sh 150`,
then queried all four tools:

| Check | Result |
|---|---|
| Stack boot | 5 containers (collector + Victoria ×3 + sample-app) all healthy |
| **Write path** | app → collector → all 3 stores receiving (success 54 / error 12) |
| **Read path** | `logs.sh` / `metrics.sh` / `traces.sh` / `correlate.sh` all returned real data |
| **Correlation** | error log (`checkout failed` + trace_id) → `correlate.sh` → same trace's `GET /api/checkout` span showed `http.status_code=500`, `error=true`, 17.4ms |
| Effect metrics | error rate 18.7%, p95 4.75s |
| External app | a second app appeared alongside `sample-app` in the trace service list → bring-your-own-app path proven |

Reproduce in [Reproduce](#reproduce).

### Prerequisites

- **Docker** (Docker Desktop or Engine) — runs all 5 containers.
- **`jq`** — the `./obs/*.sh` query scripts use it to pretty-print JSON
  (`brew install jq` / `apt install jq`).
- **`make`** *(optional)* — convenience wrapper. Without it, run
  `docker compose up -d` directly (raw commands are in `Makefile`).
- Your app must emit **OTLP**. If it doesn't yet, see
  [docs/CONNECT.md](./docs/CONNECT.md) (Node / Python / Java / Go).

### Quick start

**Want to attach your own app?** → **[docs/CONNECT.md](./docs/CONNECT.md)**. Summary:
`make up` (infra only), then send your app to `http://localhost:4318` with
`OTEL_SERVICE_NAME=my-app`.

**Just want the self-contained demo?**

```bash
# 1. Start infra + bundled sample app
make demo           # = docker compose --profile demo up -d --build

# 2. Generate traffic
./workload/run.sh 300

# 3. Observe (the very tools the agent uses)
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'
./obs/logs.sh '_time:5m severity_text:error' 20
./obs/traces.sh search-errors sample-app

# 4. (optional) run a browser UI journey
cd e2e && npm install && npm run install-browsers && npm test
```

Sample app UI: <http://localhost:3000>.

> `make up` starts **only the shared infra** (collector + 3 stores) — the
> bring-your-own-app default. `make demo` adds the bundled sample app.

### Reproduce

```bash
make demo                                  # full stack
./workload/run.sh 150                       # load (~10% intentional failures)
sleep 12                                    # wait for metric export interval (10s)

# 1) metrics — success/error counts
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'
# 2) traces — services reporting + error traces
./obs/traces.sh services
./obs/traces.sh search-errors sample-app 5
# 3) logs — pull one error log and grab its trace_id
./obs/logs.sh '_time:10m severity_text:error' 1
# 4) correlate — that trace_id's spans + logs in one shot
./obs/correlate.sh <trace_id-from-step-3>
```

Expected: metrics show success/error counts, traces show `sample-app`, and
correlate output shows the `GET /api/checkout` span with `http.status_code=500`.

### Connect your own app (the two-layer model)

This is **not** a library you install *into* each project. It is one shared
backend that every project *points at*. Two layers:

```
Layer 1 — backend (ONE copy)              Layer 2 — per app (tiny)
~/agent-otel-stack/             each project's own folder
  make up  →  5 containers                  4 env vars (+ otel.js for Node)
  shared by every local app                 emit OTLP to :4318
```

**Layer 2 — the only per-app footprint.** Set four env vars and run your app:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # the collector
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app                            # unique per app
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

Per-language setup (full detail in **[docs/CONNECT.md](./docs/CONNECT.md)**):

| Language | What lands in your app folder | New files |
|---|---|---|
| **Node/TS** | copy `app/src/otel.js` + deps + `--require ./otel.js` | 1 (`otel.js`) |
| **Python** | `pip install` + wrap launch with `opentelemetry-instrument` | 0 (env only) |
| **Java** | `-javaagent:opentelemetry-javaagent.jar` | 1 (jar) |
| **Go** | set up SDK in `main()` with OTLP/HTTP exporters | code edit |

Multiple apps? They all land in the same stores; filter by service name:

```bash
./obs/logs.sh   '_time:15m service.name:my-app severity_text:error'
./obs/metrics.sh 'sum by (outcome) (some_metric{service_name="my-app"})'
./obs/traces.sh  search my-app
```

### What's in here

| Path | What it is |
|---|---|
| `docker-compose.yml` | Orchestrates Victoria ×3 + collector + app on the `dev-observability` network |
| `otel-collector/config.yaml` | OTLP receive → fan-out to the 3 stores |
| `app/` | **Swappable** sample service (Node + zero-code OTel). Replace with your own. |
| `obs/` | Agent query tools: `logs.sh` (LogQL), `metrics.sh` (PromQL), `traces.sh` (Jaeger), `correlate.sh` |
| `workload/run.sh` | Synthetic load generator |
| `e2e/` | Playwright browser UI journey |
| `AGENTS.md` | **Operating guide every agent reads** (`CLAUDE.md` is a symlink to it) |
| `docs/ARCHITECTURE.md` | **Runtime structure** — write/read paths, collector fan-out, querying |
| `docs/CONNECT.md` | How to point your own app at the stack (per language) |

### Ports

| Service | Port | Purpose |
|---|---|---|
| sample-app | 3000 | app + UI (`http://localhost:3000`) — demo mode only |
| otel-collector | 4317 / 4318 | OTLP gRPC / HTTP ingest (**apps send here**) |
| VictoriaLogs | 9428 | LogQL query API (`logs.sh`) |
| VictoriaMetrics | 8428 | PromQL query API (`metrics.sh`) |
| VictoriaTraces | 10428 | Jaeger query API (`traces.sh`) |

### Teardown

```bash
make down          # stop (telemetry preserved in volumes)
make clean         # stop + wipe all stored telemetry (docker compose down -v)
```

### Further reading

- **[AGENTS.md](./AGENTS.md)** — the operating guide (full workflow, conventions).
- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)** — runtime internals.
- **[docs/CONNECT.md](./docs/CONNECT.md)** — attach your own app.

---

## 한국어

로컬에서 한 번 띄워두면 모든 로컬 프로젝트가 공유하는 관측 백엔드입니다. 앱은 OTLP
(`http://localhost:4318`)로 신호를 보내고, 에이전트(또는 사람)는 `./obs/*.sh`로
조회합니다. 텔레메트리를 *읽는* 데 SDK가 필요 없습니다.

### 아키텍처

```
app (OTLP) ──> OpenTelemetry Collector ──fanout──> VictoriaLogs    (LogQL)
                                                ├─> VictoriaMetrics  (PromQL)
                                                └─> VictoriaTraces   (Jaeger query)
                                                       ▲
                          ./obs/*.sh  조회 도구  +  AGENTS.md  ┘   ← 어떤 에이전트든
```

- 팬아웃은 **OpenTelemetry Collector**가 담당합니다 (Vector가 아님 — 2026년 기준 Vector의
  OTLP source는 메트릭을 못 받고 로그/메트릭을 OTLP로 내보내지 못합니다).
- **VictoriaTraces는 네이티브 TraceQL이 없습니다**(2026) — **Jaeger query API**로
  조회합니다. 그래서 `obs/traces.sh`가 Jaeger식 서브커맨드를 씁니다.

### 피드백 루프

```
  app ──OTLP──> otel-collector ──fanout──> VictoriaLogs    (LogQL)
                                         ├─> VictoriaMetrics (PromQL)
                                         └─> VictoriaTraces  (Jaeger query)
                                                 │
           ┌─────────────────────────────────────┘  ./obs/*.sh  (조회 · 상관)
           ▼
  ┌──────────────────────────────────┐
  │  코딩 에이전트 (어느 것이든)        │  ← Claude Code · Codex · OpenCode · …
  │  관찰 → 상관 → 추론                │     (CLAUDE.md는 AGENTS.md로 심링크되어
  │                                  │      모든 에이전트가 하나의 소스를 읽음)
  └────────────────┬─────────────────┘
                   │  app/ 수정 · docker compose up -d --build app
                   ▼
             ┌───────────┐
             │  코드베이스 │
             └─────┬─────┘
                   │  재실행
                   ▼
       ┌──────────────────────┐
       │ workload/run.sh      │ ──▶  e2e/ (Playwright UI 여정)
       └──────────┬───────────┘
                  │  새 텔레메트리 → 다시 관찰 (루프 폐쇄)
                  └──────────────────────▶ obs tools
```

### 왜 쓰는가

코드를 고치는 에이전트(혹은 사람)에게 가장 부족한 건 **"내 변경이 실제로 어떤 영향을
줬는가"에 대한 사실 기반 피드백**입니다. 로그만 보면 단편적이고, 메트릭만 보면 *무엇이*
잘못됐는지는 알아도 *어디서·왜* 인지는 모릅니다. 이 스택은:

- **세 신호를 한 백엔드로 합칩니다** — logs·metrics·traces가 같은 곳에 쌓여 서로 연결됩니다.
- **`trace_id`로 신호를 가로질러 pivot 합니다** — "에러율이 올랐다"(metric) → "이 요청이
  실패했다"(log) → "이 코드 경로의 이 스팬에서 500이 났다"(trace)를 한 번에 추적합니다.
  (`./obs/correlate.sh`)
- **읽는 데 SDK가 필요 없습니다** — 그냥 `curl` 래퍼 4개(`./obs/*.sh`). 어떤 에이전트든
  `AGENTS.md`만 읽으면 같은 도구로 같은 루프를 돕니다.
- **한 번 켜두면 모든 로컬 프로젝트가 공유합니다** — 앱마다 `OTEL_SERVICE_NAME`만 다르게
  주면 같은 백엔드로 보고하고 나란히 조회됩니다.

### 무엇을 얻는가

이 스택을 붙이면 다음을 **수치로** 답할 수 있게 됩니다 ([검증](#검증-2026-06-09) 참고):

- **에러율** — `sum(...{outcome="error"}) / sum(...)` → 예: 18.7%
- **지연 분포** — `histogram_quantile(0.95, ...)` → 예: p95 4.75s
- **실패 위치 특정** — 실패한 요청의 trace에서 어느 스팬(`GET /api/checkout`)이
  `http.status_code=500`인지 즉시 확인
- **before/after 비교** — 코드 수정 후 같은 워크로드를 재실행해 에러율·지연이 실제로
  내려갔는지 객관 확인

즉 "고친 것 같다"가 아니라 **"에러율 18.7% → 0%로 떨어졌다"**고 말할 수 있습니다.

### 검증 (2026-06-09)

> 최종 검증일 **2026-06-09**. 아래는 실제 실행 결과입니다(주장 아님).

`make demo`로 풀스택을 띄우고 `./workload/run.sh 150`으로 부하를 준 뒤 네 도구를 모두 조회:

| 검증 항목 | 결과 |
|---|---|
| 스택 기동 | 5개 컨테이너(collector + Victoria 3종 + sample-app) 전부 healthy |
| **Write path** | app → collector → 3종 저장소 모두 수신 (success 54 / error 12) |
| **Read path** | `logs.sh` / `metrics.sh` / `traces.sh` / `correlate.sh` 4종 모두 실데이터 반환 |
| **상관관계** | 에러 로그(`checkout failed` + trace_id) → `correlate.sh` → 같은 trace의 `GET /api/checkout` 스팬에서 `http.status_code=500`, `error=true`, 17.4ms 확인 |
| 효과 지표 | 에러율 18.7%, p95 4.75s 산출 |
| 외부 앱 연결 | 트레이스 서비스 목록에 `sample-app`과 별도 앱이 동시 노출 → bring-your-own-app 경로 실증 |

재현은 [검증 재현](#검증-재현) 절 참고.

### 사전 요구

- **Docker**(Docker Desktop 또는 Engine) — 5개 컨테이너를 실행.
- **`jq`** — `./obs/*.sh` 조회 스크립트가 JSON을 정리 출력할 때 사용
  (`brew install jq` / `apt install jq`).
- **`make`** *(선택)* — 편의 래퍼. 없으면 `docker compose up -d`로 직접 실행
  (원시 명령은 `Makefile` 참고).
- 본인 앱이 **OTLP**를 송신해야 함. 아직이면
  [docs/CONNECT.md](./docs/CONNECT.md) 참고 (Node / Python / Java / Go).

### Quick start

**내 앱을 붙이려면?** → **[docs/CONNECT.md](./docs/CONNECT.md)**. 요약:
`make up`(인프라만) 후 내 앱을 `http://localhost:4318`로 보내고
`OTEL_SERVICE_NAME=my-app` 지정.

**자체 완결 데모만 보고 싶다면:**

```bash
# 1. 인프라 + 번들 샘플 앱 기동
make demo           # = docker compose --profile demo up -d --build

# 2. 트래픽 생성
./workload/run.sh 300

# 3. 관찰 (에이전트가 쓰는 바로 그 도구들)
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'
./obs/logs.sh '_time:5m severity_text:error' 20
./obs/traces.sh search-errors sample-app

# 4. (선택) 브라우저 UI 여정 실행
cd e2e && npm install && npm run install-browsers && npm test
```

샘플 앱 UI: <http://localhost:3000>.

> `make up`은 **공유 인프라만**(collector + 저장소 3종) 띄웁니다 — bring-your-own-app
> 기본값. `make demo`는 여기에 샘플 앱을 더합니다.

### 검증 재현

```bash
make demo                                  # 풀스택 기동
./workload/run.sh 150                       # 부하 (약 10%는 의도적 실패)
sleep 12                                    # 메트릭 export 주기(10s) 대기

# 1) metrics — 성공/실패 카운트
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'
# 2) traces — 보고 중인 서비스 + 에러 트레이스
./obs/traces.sh services
./obs/traces.sh search-errors sample-app 5
# 3) logs — 에러 로그에서 trace_id 하나 뽑기
./obs/logs.sh '_time:10m severity_text:error' 1
# 4) correlate — 그 trace_id로 스팬 + 로그를 한 번에
./obs/correlate.sh <trace_id-from-step-3>
```

기대 결과: metrics에 success/error 카운트, traces에 `sample-app`,
correlate 출력에서 `GET /api/checkout` 스팬의 `http.status_code=500`.

### 내 앱 연결 (두-층 모델)

이건 각 프로젝트에 *설치하는* 라이브러리가 아닙니다. 모든 프로젝트가 *가리키는* 공유
백엔드가 하나 있습니다. 두 층:

```
층1 — 백엔드 (1개만)                    층2 — 앱마다 (아주 작음)
~/agent-otel-stack/          각 프로젝트 폴더
  make up  →  컨테이너 5개               env 4개 (+ Node면 otel.js 1개)
  모든 로컬 앱이 공유                    :4318로 OTLP 송신
```

**층2 — 앱마다 생기는 것은 이것뿐.** env 4개를 설정하고 앱을 실행:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # 컬렉터
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app                            # 앱마다 유일
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

언어별 설정 (상세는 **[docs/CONNECT.md](./docs/CONNECT.md)**):

| 언어 | 내 앱 폴더에 생기는 것 | 새 파일 |
|---|---|---|
| **Node/TS** | `app/src/otel.js` 복사 + 의존성 + `--require ./otel.js` | 1개 (`otel.js`) |
| **Python** | `pip install` + `opentelemetry-instrument`로 실행 감싸기 | 0개 (env만) |
| **Java** | `-javaagent:opentelemetry-javaagent.jar` | 1개 (jar) |
| **Go** | `main()`에 OTLP/HTTP exporter로 SDK 세팅 | 코드 수정 |

여러 앱이면? 전부 같은 저장소에 쌓이고, 서비스 이름으로 필터:

```bash
./obs/logs.sh   '_time:15m service.name:my-app severity_text:error'
./obs/metrics.sh 'sum by (outcome) (some_metric{service_name="my-app"})'
./obs/traces.sh  search my-app
```

### 구성

| 경로 | 설명 |
|---|---|
| `docker-compose.yml` | Victoria 3종 + collector + app을 `dev-observability` 네트워크에 오케스트레이션 |
| `otel-collector/config.yaml` | OTLP 수신 → 3종 저장소로 fan-out |
| `app/` | **교체 가능한** 샘플 서비스 (Node + zero-code OTel). 내 앱으로 바꿔 관측. |
| `obs/` | 에이전트 조회 도구: `logs.sh`(LogQL), `metrics.sh`(PromQL), `traces.sh`(Jaeger), `correlate.sh` |
| `workload/run.sh` | 합성 부하 생성기 |
| `e2e/` | Playwright 브라우저 UI 여정 |
| `AGENTS.md` | **모든 에이전트가 읽는 운영 가이드** (`CLAUDE.md`가 심링크) |
| `docs/ARCHITECTURE.md` | **런타임 동작 구조** — write/read path, 컬렉터 fan-out, 조회 방식 |
| `docs/CONNECT.md` | 내 앱을 OTLP로 붙이는 법 (언어별) |

### 포트

| 서비스 | 포트 | 용도 |
|---|---|---|
| sample-app | 3000 | 앱 + UI (`http://localhost:3000`) — demo 모드만 |
| otel-collector | 4317 / 4318 | OTLP gRPC / HTTP 수신 (**앱이 여기로 쏨**) |
| VictoriaLogs | 9428 | LogQL 쿼리 API (`logs.sh`) |
| VictoriaMetrics | 8428 | PromQL 쿼리 API (`metrics.sh`) |
| VictoriaTraces | 10428 | Jaeger 쿼리 API (`traces.sh`) |

### 종료

```bash
make down          # 정지 (텔레메트리는 볼륨에 보존)
make clean         # 정지 + 저장된 텔레메트리 전부 삭제 (docker compose down -v)
```

### 더 보기

- **[AGENTS.md](./AGENTS.md)** — 운영 가이드 (전체 워크플로, 규칙).
- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)** — 런타임 내부 구조.
- **[docs/CONNECT.md](./docs/CONNECT.md)** — 내 앱 연결법.
