# ObservabilityStack 동작 구조 (런타임 아키텍처)

> 이 문서는 **이 스택이 실제로 어떻게 돌아가는가**를 설명한다.
> - 도구 *사용법*은 [`AGENTS.md`](../AGENTS.md)
> - 내 앱 *연결법*은 [`docs/CONNECT.md`](./CONNECT.md)
>
> 모든 내용은 실제 파일(`docker-compose.yml`, `otel-collector/config.yaml`, `obs/*.sh`) 기준.

---

## 0. 한 문장 요약

**앱은 컬렉터(`:4318`) 하나에만 텔레메트리를 쏘고, 컬렉터가 그걸 받아 3종 저장소로 복제한다.
너(또는 에이전트)는 `./obs/*.sh`로 그 저장소들의 쿼리 API를 직접 조회한다.**

- 들어가는 길(write): `앱 → OTLP → 컬렉터 → fan-out → Victoria 3종`
- 읽는 길(read): `./obs/*.sh → curl → Victoria 3종의 쿼리 API`

이 둘은 완전히 독립이다. 쓰기는 OTLP 푸시, 읽기는 HTTP 풀(pull). 서로 모른다.

---

## 1. 전체 그림

```
[ 관측 대상 앱 ]                                   [ 사람 / 코딩 에이전트 ]
  OTel SDK                                           ./obs/*.sh (그냥 curl)
     │ OTLP (http/protobuf)                                │ 쿼리 API (HTTP GET)
     │                                                     │
     ▼ :4318 (HTTP) · :4317 (gRPC)                         │
┌───────────────────────────────────┐                     │
│  otel-collector  (단일 fan-out 점)  │                     │
│                                   │                     │
│  receivers:  otlp (grpc+http)     │                     │
│  processors: resource_detection   │                     │
│              batch (5s / 1024)    │                     │
│  exporters:  ▼ logs  ▼ metrics  ▼ traces  (+debug echo)  │
└──────┬─────────────┬─────────────┬┘                     │
       │ logs        │ metrics     │ traces               │
       ▼             ▼             ▼                       │
 ┌───────────┐ ┌────────────┐ ┌────────────┐              │
 │VictoriaLogs│ │Victoria    │ │Victoria    │  ◀───────────┘
 │  :9428    │ │Metrics:8428│ │Traces:10428│   읽기(조회)
 │  LogQL    │ │  PromQL    │ │ Jaeger API │
 └───────────┘ └────────────┘ └────────────┘
   vlogs vol    vmdata vol     vtraces vol   (도커 볼륨에 영속)

           전부 도커 네트워크 `dev-observability` 안
```

핵심: **앱은 저장소 3개의 존재를 모른다.** 컬렉터 하나(`:4318`)만 안다.
저장소를 늘리거나 바꿔도 앱은 그대로 — 컬렉터의 exporter 설정만 바뀐다.

---

## 2. 구성요소 (5개 컨테이너)

`docker-compose.yml`이 띄우는 것들. 전부 `dev-observability` 네트워크에 붙는다.

| 컨테이너 | 이미지 | 포트(호스트:컨테이너) | 역할 |
|---|---|---|---|
| `otel-collector` | `otel/opentelemetry-collector-contrib` | `4317:4317`(gRPC), `4318:4318`(HTTP) | 모든 신호의 **유일한 입구**. 받아서 3종으로 복제 |
| `victorialogs` | `victoriametrics/victoria-logs` | `9428:9428` | 로그 저장 + LogQL 쿼리 API + OTLP 로그 수신 |
| `victoriametrics` | `victoriametrics/victoria-metrics` | `8428:8428` | 메트릭 저장 + PromQL 쿼리 API + OTLP 메트릭 수신 |
| `victoriatraces` | `victoriametrics/victoria-traces` | `10428:10428` | 트레이스 저장 + Jaeger 쿼리 API + OTLP 트레이스 수신 |
| `app` (선택) | `./app` 빌드 | `3000:3000` | 번들 샘플 앱. **`demo` 프로파일**에서만 뜸 |

### 왜 컬렉터가 따로 필요한가? (Victoria가 직접 OTLP를 받는데도)

각 Victoria 저장소는 사실 자기 OTLP 엔드포인트를 갖고 있다(표의 "OTLP … 수신"). 그런데도
컬렉터를 두는 이유:

1. **앱 입장의 단일 진입점.** 앱은 `:4318` 하나만 알면 된다. 로그/메트릭/트레이스가 각각
   다른 포트로 가는 걸 앱이 신경 쓸 필요 없음.
2. **fan-out(복제)이 한 곳에서.** 신호별로 어느 저장소로 보낼지를 컬렉터가 결정.
3. **가공 지점.** batching, 리소스 속성 보존, (장차) 시크릿 redaction 등을 한 곳에서.

> **2026 설계 노트 (Vector를 안 쓰는 이유):** Vector의 OpenTelemetry source는 OTLP **메트릭을
> 못 받고** 로그/메트릭을 OTLP로 **내보내지 못한다**. OpenTelemetry Collector는 3종을 모두
> 네이티브로 fan-out 하므로 이걸 쓴다.

---

## 3. Write Path — 텔레메트리가 쌓이는 과정

### 3.1 앱이 OTLP로 쏜다

앱은 OTel SDK를 통해 환경변수 몇 개만 설정하면 된다. `docker-compose.yml`의 샘플 앱이 예시:

```yaml
OTEL_SERVICE_NAME: sample-app                          # 나중에 필터하는 키 (앱마다 유일하게)
OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318 # 컨테이너 내부. 호스트 실행 시 localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
OTEL_METRIC_EXPORT_INTERVAL: "10000"                   # 메트릭 push 주기 10s (기본 60s)
OTEL_RESOURCE_ATTRIBUTES: deployment.environment=dev,service.namespace=demo
```

- **호스트에서 도는 앱**(예: 내 서비스)은 `localhost:4318`로 보낸다. 4317/4318이 호스트에
  공개돼 있어서 가능.
- **같은 도커 네트워크 안의 앱**은 `otel-collector:4318` (서비스 이름)로 보낸다.
- 신호 송신 방식 차이:
  - **트레이스/로그**: 이벤트 발생 즉시(배치돼서) push
  - **메트릭**: `OTEL_METRIC_EXPORT_INTERVAL` 주기로 push (그래서 메트릭은 약간 늦게 보임)

### 3.2 OTel SDK가 자동으로 해주는 것 (중요)

이게 나중에 **상관관계(correlate)** 가 가능한 이유다:

- 모든 **로그 레코드에 `trace_id` / `span_id`를 자동 주입**한다.
- → "이 에러 로그"가 "이 트레이스의 이 스팬"에서 났다는 연결이 데이터에 박힌다.
- → 메트릭(무언가 잘못됨) → 로그(에러 메시지 + trace_id) → 트레이스(전체 코드 경로)로
  pivot 할 수 있다.

### 3.3 컬렉터가 받아서 fan-out

`otel-collector/config.yaml`의 파이프라인. 신호별로 3갈래로 갈라진다:

```
receivers.otlp (grpc :4317 / http :4318)
        │
        ├── pipeline: logs    → [resource_detection, batch] → victorialogs:9428/insert/opentelemetry/v1/logs
        ├── pipeline: metrics → [resource_detection, batch] → victoriametrics:8428/opentelemetry/v1/metrics
        └── pipeline: traces  → [resource_detection, batch] → victoriatraces:10428/insert/opentelemetry/v1/traces
                                                              (+ 모든 파이프라인에 debug echo)
```

- **`batch` 프로세서**: 5초 또는 1024개가 모이면 한 번에 전송. 네트워크 효율.
- **`resource_detection` 프로세서** (`detectors: [env]`): SDK가 붙인 호스트/프로세스 등
  리소스 속성을 보존.
- **`debug` exporter**: 콘솔로도 echo. `docker compose logs otel-collector`로 들어오는
  데이터를 눈으로 확인할 때 유용.

### 3.4 Victoria 3종이 저장

각 저장소가 OTLP를 받아 자기 포맷으로 저장하고, 도커 볼륨에 영속화한다
(`victorialogs-data`, `victoriametrics-data`, `victoriatraces-data`).

- 메트릭은 `opentelemetry.usePrometheusNaming=true` 설정 때문에 OTLP의 점(`.`) 표기가
  Prometheus 스타일 밑줄(`_`)로 바뀐다. → PromQL에선 `service_name`, `orders_processed_total`처럼 조회.

---

## 4. Read Path — 조회하는 과정

`./obs/*.sh`는 **SDK도 클라이언트 라이브러리도 아니다.** 각 저장소의 HTTP 쿼리 API를
때리는 얇은 `curl` 래퍼일 뿐이다. (`obs/common.sh`에 URL 3개 정의 + `jq` pretty-print)

```bash
VL_URL=${VL_URL:-http://localhost:9428}   # VictoriaLogs
VM_URL=${VM_URL:-http://localhost:8428}   # VictoriaMetrics
VT_URL=${VT_URL:-http://localhost:10428}  # VictoriaTraces
```

> 원격/다른 호스트면 이 env 3개만 덮어쓰면 된다. 예: `VL_URL=http://remote:9428 ./obs/logs.sh ...`

| 스크립트 | 대상 | 쿼리 언어 | 실제 호출하는 엔드포인트 |
|---|---|---|---|
| `logs.sh '<LogQL>' [limit]` | VictoriaLogs | **LogQL** | `GET /select/logsql/query` |
| `metrics.sh '<PromQL>' [range <step>]` | VictoriaMetrics | **PromQL** | `GET /api/v1/query` 또는 `/api/v1/query_range` |
| `traces.sh <subcmd> ...` | VictoriaTraces | **Jaeger query API** | `/select/jaeger/api/...` |
| `correlate.sh <traceID>` | Traces + Logs 동시 | 둘 다 | 아래 §4.2 |

### 4.1 각 스크립트의 동작

**`logs.sh`** — LogQL 쿼리 한 방.
```bash
./obs/logs.sh '_time:5m severity_text:error' 20
```
- 시간 범위는 `_time:5m` / `_time:1h` 같은 LogQL 필터로 준다.
- **로그 레벨 필드는 `severity_text`** (`info`/`warn`/`error`) — `level` 아님(OTLP 규약).
- 결과는 줄단위 JSON(NDJSON). 각 줄에 `trace_id`가 들어있어 트레이스로 pivot 가능.

**`metrics.sh`** — 순간값 또는 범위 쿼리.
```bash
./obs/metrics.sh 'sum by (outcome) (orders_processed_total)'                 # 지금 값
./obs/metrics.sh 'rate(orders_processed_total{outcome="error"}[1m])' range 15s # 최근 15분 추이
```
- 기본은 instant(`/api/v1/query`). 두 번째 인자가 `range`면 최근 15분을 `step` 간격으로
  쿼리(`/api/v1/query_range`).
- rate 윈도는 `[1m]` / `[5m]`처럼 PromQL 문법으로.

**`traces.sh`** — Jaeger 스타일 서브커맨드.
```bash
./obs/traces.sh services                    # 지금 신호 보내는 서비스 목록
./obs/traces.sh search sample-app 20 1h      # 최근 트레이스
./obs/traces.sh search-errors sample-app     # 에러 트레이스만 (tags={"error":"true"})
./obs/traces.sh get <traceID>                # 트레이스 전체
```
> VictoriaTraces는 2026 기준 **네이티브 TraceQL이 없다.** 그래서 Jaeger query API로 조회한다.
> 그게 traces.sh가 Jaeger식 서브커맨드를 쓰는 이유.

### 4.2 `correlate.sh` — 이 스택의 핵심 동작

trace_id 하나로 **세 신호를 한 번에** 엮는다. 에이전트의 가장 중요한 한 수.

```bash
./obs/correlate.sh <trace_id> [lookback]
```

내부 동작 두 단계:
1. **VictoriaTraces**에서 그 trace의 스팬들을 가져와 요약 출력
   (operationName, 소요시간 ms, `error`/`http.status_code` 태그).
2. **VictoriaLogs**에서 `_time:<lookback> trace_id:<id>`로 **같은 trace_id를 가진 모든 로그**를 가져옴.

→ "뭔가 느리다/깨졌다"에서 → "정확히 이 코드 경로 + 이 로그 맥락"으로 점프.

---

## 5. 피드백 루프 (observe → reason → change → re-run)

`AGENTS.md`가 말하는 그 루프를, 위 write/read path로 다시 쓰면:

```
1. 신호 생성   workload/run.sh 300        # 앱에 트래픽 → write path로 텔레메트리 쌓임
                                          # (외부 앱이면 그냥 평소대로 돌리면 됨)
2. 관찰        obs/metrics.sh '...'        # read path. 에러율/p95로 이상 탐지
3. 상관관계    obs/logs.sh ...severity_text:error  → 에러 로그 1건의 trace_id 추출
              obs/correlate.sh <trace_id> # 스팬 + 그 trace의 모든 로그를 한 번에
4. 추론·수정   앱 코드 수정 (어느 스팬/로그에서 터졌는지 보고)
5. 재실행      docker compose up -d --build app && workload/run.sh 300
6. 비교        obs/metrics.sh '...'        # 에러율 떨어졌는지 before/after 비교
```

> 규칙: **결론 내기 전에 항상 correlate 하라.** 메트릭은 *무엇이* 잘못됐는지만 알려준다.
> 트레이스+로그가 *어디서, 왜* 를 알려준다.

`workload/run.sh`는 샘플 앱 전용 부하 생성기다(`/api/orders`, `/api/checkout`에 트래픽,
약 10%는 강제 실패). 외부 앱을 관측할 땐 필요 없다 — 그 앱을 평소대로 돌리면 된다.

---

## 6. 두 가지 실행 모드

| 명령 | 뜨는 것 | 용도 |
|---|---|---|
| `make up` | 컬렉터 + Victoria 3종 (**인프라만**) | **내 앱 가져다 붙이기**(bring-your-own-app). 내 앱을 붙일 때 쓰는 모드 |
| `make demo` | 위 + 번들 샘플 앱(`:3000`) | 자체 완결 데모/학습. `/api/checkout`에 ~15% 의도적 결함 |

샘플 앱이 `demo` 프로파일 뒤에 숨어 있어서(`docker-compose.yml`의 `profiles: ["demo"]`),
그냥 `docker compose up`(=`make up`)은 인프라만 띄운다.

여러 앱을 동시에 붙여도 된다. 전부 같은 저장소에 쌓이고, 조회 때 `OTEL_SERVICE_NAME`으로
구분한다:
```bash
./obs/logs.sh '_time:15m service.name:my-app severity_text:error'
./obs/metrics.sh 'sum by (outcome) (some_metric{service_name="my-app"})'
./obs/traces.sh search my-app
```

---

## 7. 라이프사이클 / 데이터 영속성

```bash
make up          # 인프라 기동
make demo        # 인프라 + 샘플 앱
make load N=500  # 샘플 앱에 부하 (= ./workload/run.sh 500)
make logs        # 컬렉터+앱 로그 tail
make ps          # 상태 확인
make down        # 정지 (데이터는 볼륨에 남음)
make clean       # 정지 + 저장된 텔레메트리 전부 삭제 (docker compose down -v)
```

- 텔레메트리는 도커 볼륨 3개에 **영속**된다. `make down`은 컨테이너만 멈추고 데이터는 보존.
- `make clean`은 볼륨까지 삭제 → 깨끗한 상태로 리셋.

---

## 8. 포트 한눈에

| 서비스 | 포트 | 용도 |
|---|---|---|
| sample-app | 3000 | 앱 + UI (`http://localhost:3000`) — demo 모드만 |
| otel-collector | 4317 / 4318 | OTLP gRPC / HTTP 수신 (**앱이 여기로 쏨**) |
| VictoriaLogs | 9428 | LogQL 쿼리 API (`logs.sh`가 조회) |
| VictoriaMetrics | 8428 | PromQL 쿼리 API (`metrics.sh`가 조회) |
| VictoriaTraces | 10428 | Jaeger 쿼리 API (`traces.sh`가 조회) |

---

## 9. 자주 막히는 지점 (FAQ)

- **메트릭이 안 보임** → 메트릭은 `OTEL_METRIC_EXPORT_INTERVAL` 주기로만 push된다.
  샘플 앱은 10s. 몇 초 기다리거나 export interval을 줄여라.
- **로그 레벨로 필터가 안 됨** → 필드는 `severity_text`다. `level`이 아니다.
- **트레이스가 TraceQL로 안 됨** → VictoriaTraces는 TraceQL이 없다. `traces.sh`의 Jaeger
  서브커맨드를 써라.
- **PromQL에서 라벨이 점 표기로 안 잡힘** → OTLP 점(`.`)이 밑줄(`_`)로 변환된다.
  `service.name` → `service_name`.
- **컬렉터가 데이터를 받는지 모르겠음** → `docker compose logs otel-collector` (debug
  exporter가 콘솔로 echo 함).
- **앱이 컬렉터에 못 붙음** → 호스트 실행이면 `localhost:4318`, 같은 도커 네트워크면
  `otel-collector:4318`. 둘을 헷갈리면 연결 실패.
