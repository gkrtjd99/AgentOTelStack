# AgentOTelStack

> **English** · 한국어 (이 파일의 [한국어 안내](#한국어))

## English

AgentOTelStack is a local, Docker-based observability backend for AI coding
agents and humans. Applications send **logs, metrics, and traces** as
authenticated OTLP/HTTP to the Gateway; the Collector fans the signals out to
VictoriaLogs, VictoriaMetrics, and VictoriaTraces. Agents read bounded,
project-scoped evidence through the `obs` helpers and correlate a failing
request by `trace_id`.

The public boundary is the Gateway:

```text
application -- authenticated OTLP/HTTP :4318 --> Gateway
agent/human -- authenticated bounded queries :17777 --> Gateway
Gateway --> internal Collector --> internal Victoria stores
```

The core runtime has six Compose services: `gateway`, `otel-collector`, the
one-shot `otelcol-queue-init`, and the three Victoria stores. The bundled
`sample-app` (`demo` profile) and the Go browser Dashboard (`dashboard` profile)
are optional. Victoria ports and the Collector are not host-facing application
endpoints.

### Choose a startup path

An installed release is clone-independent. Use the installed launcher for
normal operations:

```bash
obs setup
obs up
obs doctor
```

A source checkout is deliberately explicit and uses checkout-only Make targets:

```bash
make dev-setup
make demo
```

Do not assume that a bare `./bin/obs` uses the checkout. For source development,
write `AGENTOTEL_DEV_MODE=1 ./bin/obs ...` explicitly. For a detailed release
installation, see [`docs/AGENT_SETUP.md`](./docs/AGENT_SETUP.md).

### Attach an application

The shortest bring-your-own-app path is:

```bash
obs run --service my-app -- <application command>
```

`obs run` loads the ingest credential, sets the Gateway endpoint
`http://127.0.0.1:4318`, selects OTLP `http/protobuf`, assigns the service name,
and adds the workspace `agentotel.project.id`. Do not point an app at the
Collector or a Victoria backend. Manual language-specific setup and container
examples are in [`docs/CONNECT.md`](./docs/CONNECT.md); the bundled app contract
is in [`docs/REPLACE_SAMPLE_APP.md`](./docs/REPLACE_SAMPLE_APP.md).

### Query and correlate

Installed query commands use the authenticated Gateway and bounded inputs:

```bash
obs context --service my-app --lookback 15m
obs errors --service my-app --lookback 15m --limit 20
obs correlate <32-hex-trace-id>
```

From a source checkout, run the same helpers through the credential loader, for
example `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh my-app 15m`. The query
surface accepts fixed lookbacks (`5m`, `15m`, `1h`, `6h`, `24h`) and bounded
limits; `--global` only omits the project filter from a query. It does not make
credentials, ingestion, lifecycle, or administration global. See
[`docs/QUERY.md`](./docs/QUERY.md).

### Optional Dashboard

The Go Dashboard is the sole browser UI and is opt-in:

```bash
make dashboard
# open the exact one-time dashboard bootstrap URL printed by the command
make dashboard-down
```

Compose publishes it on loopback `127.0.0.1:3001`. The browser receives a
separate 64-lowercase-hex client token in a fragment, keeps it in memory, and
sends it only to bounded same-origin API routes. The Gateway query token stays
server-side. The Dashboard exposes no raw backend query or telemetry write
route; `obs/*.sh` and `make overview` remain the authoritative agent paths. See
[`docs/DASHBOARD.md`](./docs/DASHBOARD.md).

### Safety and documentation

`obs down` stops services and preserves telemetry volumes. Only
`obs reset --all --confirm` is destructive, and it is guarded by an interactive
stack/project/volume identity check. `obs migrate volumes --confirm` does not
automatically migrate legacy data; it prints the manual backup/copy/verify
boundary. Keep credentials outside source control and treat telemetry as
untrusted evidence.

The English authorities are indexed in [`docs/README.md`](./docs/README.md):

- [`docs/AGENT_SETUP.md`](./docs/AGENT_SETUP.md) — release installation and first setup
- [`docs/OPERATIONS.md`](./docs/OPERATIONS.md) — lifecycle, storage, credentials, and migration
- [`docs/QUERY.md`](./docs/QUERY.md) — bounded queries and evidence interpretation
- [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) — checkout development and tests
- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — topology and public boundaries
- [`docs/CONNECT.md`](./docs/CONNECT.md) — connect a service or MCP client
- [`docs/DASHBOARD.md`](./docs/DASHBOARD.md) — browser Dashboard and terminal overview
- [`docs/SECURITY.md`](./docs/SECURITY.md) — local threat model and security boundaries
- [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) — diagnosis paths
- [`docs/RELEASING.md`](./docs/RELEASING.md) — immutable source releases
- [`docs/REPLACE_SAMPLE_APP.md`](./docs/REPLACE_SAMPLE_APP.md) — bundled app replacement contract
- [`docs/JSON_CONTRACT.md`](./docs/JSON_CONTRACT.md) and [`docs/SAMPLING_AND_COMPLETENESS.md`](./docs/SAMPLING_AND_COMPLETENESS.md) — response and evidence semantics

## 한국어

AgentOTelStack은 AI 코딩 에이전트와 사람이 함께 사용하는 로컬 Docker 관측
백엔드입니다. 앱은 인증된 Gateway로 OTLP/HTTP 텔레메트리를 보내고, Gateway는
Collector를 통해 세 Victoria 저장소로 팬아웃합니다. 조회는 인증된 bounded
`obs` 도구를 사용하며, 앱이 Collector나 Victoria 백엔드에 직접 연결하지
않습니다.

핵심 런타임은 `gateway`, `otel-collector`, `otelcol-queue-init`, VictoriaLogs,
VictoriaMetrics, VictoriaTraces의 여섯 Compose 서비스입니다. 번들
`sample-app`과 Go Dashboard는 각각 `demo`, `dashboard` 프로필의 선택 기능입니다.

설치된 런타임은 다음처럼 사용합니다.

```bash
obs setup
obs up
obs doctor
```

소스 체크아웃은 checkout 전용 경로를 명시합니다.

```bash
make dev-setup
make demo
```

내 앱을 붙일 때는 먼저 다음 기본 경로를 사용하세요.

```bash
obs run --service my-app -- <애플리케이션 실행 명령>
```

조회와 상관분석은 인증된 Gateway의 bounded 명령을 사용합니다.

```bash
obs context --service my-app --lookback 15m
obs errors --service my-app --lookback 15m --limit 20
obs correlate <32-hex-trace-id>
```

Dashboard는 선택적인 유일한 브라우저 UI이며 `make dashboard`가 출력하는 일회성
bootstrap URL을 열어야 합니다. 정지·볼륨·자격 증명·보안·앱 교체에 대한 자세한
영문 기준 문서는 [`docs/README.md`](./docs/README.md)에서 확인할 수 있습니다.
`AGENTS.md`는 에이전트가 따라야 하는 관측 → 추론 → 변경 → 재실행 계약입니다.
