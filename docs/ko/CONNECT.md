# Application 또는 MCP client 연결

[English](../CONNECT.md) · [한국어](./CONNECT.md)

AgentOTelStack은 모든 application에 설치해야 하는 library가 아니라 공유 backend입니다. Application은 인증된 OTLP/HTTP를 Gateway로 보내고, query tool은 Gateway를 통해 결과 evidence를 읽습니다. Application을 Collector나 Victoria backend에 직접 연결하지 마세요.

## 권장 경로: `obs run`

먼저 설치된 공유 runtime을 시작한 뒤 launcher가 application ingest environment를 제공하게 하세요.

```bash
obs setup
obs up
obs run --service my-app -- <application command> [args...]
```

Source checkout에서는 source 선택을 명시하세요.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
AGENTOTEL_DEV_MODE=1 ./bin/obs run --service my-app -- <application command> [args...]
```

`obs run`은 0600 credential store에서 ingest 역할만 읽고, `OTEL_SERVICE_NAME`을 설정하며, `OTEL_EXPORTER_OTLP_ENDPOINT`를 `http://127.0.0.1:4318`로 기본 설정하고, `OTEL_EXPORTER_OTLP_PROTOCOL`을 `http/protobuf`로 설정하며, URL-encoded bearer header `Authorization=Bearer%20<ingest-token>`를 설정합니다. `obs project ensure`로 workspace project를 해석하고 `agentotel.project.id=<UUIDv4>`를 `OTEL_RESOURCE_ATTRIBUTES` 앞에 추가합니다. Child를 시작하기 전에 credential variable을 제거하고 `obs runs`/`obs stop`을 위한 제한된 local process scope를 기록합니다. Service name에는 letters, numbers, `.`, `_`, `-`만 사용하세요.

공유 runtime은 여러 application을 받을 수 있습니다. 각각에 서로 다른 `OTEL_SERVICE_NAME`을 주고, 같은 workspace에 속한 application이라면 동일한 workspace project를 유지하세요.

## 수동 OTLP environment

Application의 launcher를 `obs run`으로 감쌀 수 없을 때만 사용하세요. Workspace에서 project identity를 얻고 **ingest** token을 secret manager 또는 보호된 environment로 제공하세요. Query token을 재사용하지 마세요.

```bash
PROJECT_ID="$(obs project ensure)"
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-app
export OTEL_RESOURCE_ATTRIBUTES="agentotel.project.id=${PROJECT_ID},deployment.environment=dev"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}"
<application command>
```

Host endpoint는 Gateway의 loopback ingest listener입니다. Compose edge network 내부에서는 `http://gateway:4318`을 사용하세요. 두 경로 모두 동일한 인증 OTLP header가 필요합니다. Query listener는 `http://127.0.0.1:17777`의 다른 역할이며 OTLP endpoint가 아닙니다.

`project.id`는 일반 workspace-scoped query correlation에 필요하지만 authentication은 아닙니다. Query의 `--global`은 project filter만 생략하며 ingest나 stack administration을 global로 만들지 않습니다.

## 언어별 예시

다음 예시는 동일한 Gateway, protocol, service, project 및 authentication contract를 유지합니다.

### Node.js / TypeScript

Repository의 OTel bootstrap pattern을 복사하세요(bundled example은 `src/app/src/otel.js`). 자신의 app에 SDK/exporter dependency를 설치하고 bootstrap이 로드된 상태로 process를 시작합니다.

```bash
node --require ./otel.js your-entry.js
```

Launcher가 credential과 project attribute를 제공하도록 `obs run --service my-node-app -- node --require ./otel.js your-entry.js`를 우선 사용하세요.

### Python

Instrumented process는 Gateway header와 project scope를 받아야 하며, endpoint만으로는 충분하지 않습니다.

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
PROJECT_ID="$(obs project ensure)"
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-py-app
export OTEL_RESOURCE_ATTRIBUTES="agentotel.project.id=${PROJECT_ID},deployment.environment=dev"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}"
export OTEL_LOGS_EXPORTER=otlp
opentelemetry-instrument python app.py
```

이 command를 실행하기 전에 보호된 credential store 또는 secret manager에서 `GATEWAY_INGEST_TOKEN`을 준비하세요. Token을 source에 붙여 넣지 마세요.

### Java

```bash
PROJECT_ID="$(obs project ensure)"
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.exporter.otlp.endpoint=http://127.0.0.1:4318 \
  -Dotel.exporter.otlp.protocol=http/protobuf \
  -Dotel.exporter.otlp.headers="Authorization=Bearer%20${GATEWAY_INGEST_TOKEN}" \
  -Dotel.service.name=my-java-app \
  -Dotel.resource.attributes="agentotel.project.id=${PROJECT_ID},deployment.environment=dev" \
  -jar your-app.jar
```

SDK가 header 설정을 다른 이름으로 부르면 동등한 `Authorization: Bearer <ingest-token>` header를 설정하세요. Gateway authentication을 비활성화하지 마세요.

### Go

OpenTelemetry OTLP/HTTP trace, metric 및 log exporter를 사용하고 동일한 endpoint/header/resource attribute를 설정하세요. 적절한 경우 `otelhttp` 또는 `otelgin` 같은 HTTP middleware를 추가합니다. Metric label은 bounded 상태로 유지하고 request body, credential 또는 high-cardinality ID를 attribute에 넣지 마세요.

## 읽기 전용 MCP adapter

설치 후 MCP client가 다음을 실행하도록 설정하세요.

```text
${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp
```

stdio를 통해 실행합니다. 정확히 `agentotel_context`, `agentotel_correlate`, `agentotel_services`를 노출합니다. 호출은 별도의 query credential과 MCP workspace에서 해석된 project를 사용합니다. Caller는 임의의 project, backend URL, raw query 또는 write operation을 제공할 수 없습니다. Adapter가 반환하는 telemetry는 instruction이 아닌 신뢰하지 않는 content입니다.

## 연결 확인

Token이 출력되지 않도록 read에는 query credential loader를 사용하세요.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/services.sh
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh my-app 15m 50
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/logs.sh my-app 15m 20
```

Collector batching과 metric export delay를 고려하세요. Service가 나타나지 않으면 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)를 따르세요. 설치된 전체 lifecycle과 credential rotation 규칙은 [`OPERATIONS.md`](./OPERATIONS.md)를 참조하세요.
