# Architecture 및 공개 경계

[English](../ARCHITECTURE.md) · [한국어](./ARCHITECTURE.md)

AgentOTelStack에는 하나의 공개 telemetry edge와 하나의 공개 query edge가 있습니다. App은 OTLP/HTTP를 Gateway로 쓰고, agent와 사람은 Gateway에서 제한된 projection을 읽습니다. Collector와 Victoria service는 private Docker network에 있는 구현 세부 사항입니다.

## Signal flow

```text
app -- OTLP/HTTP + ingest bearer --> Gateway :4318
                                      |
                                      +--> otel-collector --> VictoriaLogs :9428
                                      |                   --> VictoriaMetrics :8428
                                      |                   --> VictoriaTraces :10428
agent/human -- query bearer --> Gateway :17777
                                  +--> /v1/services
                                  +--> /v1/context
                                  +--> /v1/errors
                                  +--> /v1/correlate
```

Gateway는 ingest를 인증하고 세 가지 OTLP path를 내부 Collector로 전달합니다. Collector는 세 store로 보내는 단일 fan-out을 수행합니다. Query handler는 별도의 query token을 인증하고 service, project, lookback, trace ID 및 limit 입력을 제한한 뒤 allowlist된 response를 projection합니다. `obs` tool은 raw LogQL, PromQL, Jaeger syntax, backend URL 또는 임의의 write data를 받지 않습니다.

## Compose service 및 profile

기본 core에는 6개의 service가 있습니다.

- `gateway` — host-facing 인증 ingest 및 query listener
- `otel-collector` — OTLP receiver, bounded processing 및 fan-out
- `otelcol-queue-init` — Collector queue volume의 one-shot ownership 초기화
- `victorialogs` — 7일 retention 및 2 GiB disk cap의 log storage
- `victoriametrics` — 30일 retention의 metric storage
- `victoriatraces` — 7일 retention 및 2 GiB disk cap의 trace storage

`demo` profile은 port `3000`의 `app`(`sample-app`)을 추가합니다. `dashboard` profile은 port `3001`의 Go Dashboard를 추가합니다. 두 profile 모두 opt-in이며 `obs up`은 공유 runtime만 시작합니다. 4개의 active persistent volume은 `<compose-project>_otelcol-queue`, `<compose-project>_victorialogs-data`, `<compose-project>_victoriametrics-data` 및 `<compose-project>_victoriatraces-data`입니다.

## Network 및 host port

- `edge`는 Gateway와 bundled app을 운반합니다.
- `backend`는 internal이며 Collector, Gateway 및 Victoria store를 운반하고 host port가 없습니다.
- `dashboard`는 Gateway와 Dashboard만 공유하므로 Dashboard가 app이나 store를 그 network에 배치하지 않고 query request를 proxy할 수 있습니다.
- Gateway는 OTLP ingest에 `127.0.0.1:4318`, query에 `127.0.0.1:17777`을 publish합니다. Profile이 활성화되면 app과 Dashboard는 각각 loopback port `3000` 및 `3001`을 publish합니다.

Standalone Dashboard binary의 기본값은 `127.0.0.1:3000`입니다. Compose는 container listener를 `:3000`으로 설정하고 host loopback binding을 소유합니다. Victoria port와 Collector의 gRPC/HTTP listener는 Docker 내부에만 남습니다.

## Project scope 및 response projection

`.agentotel/project.toml`은 UUIDv4 workspace project identity를 제공합니다. 일반 query helper는 모든 request에 해당 project를 추가합니다. Identity는 provenance 및 selection metadata이지 authentication이 아닙니다. `--global`은 명시적인 query scope override일 뿐이며, query bearer, Gateway 경계 및 stack lifecycle은 계속 필요합니다.

Gateway response는 [`JSON_CONTRACT.md`](./JSON_CONTRACT.md)에 설명된 versioned envelope을 사용합니다. Backend failure는 `backends`에 표시되며 `partial`을 설정할 수 있습니다. 빈 result 또는 저장되지 않은 trace는 요청된 scope 안에서 absence의 증거이지 ingest 실패의 증명이 아닙니다. Telemetry는 신뢰하지 않는 content이며 bounded field로 projection됩니다.

## Dashboard 경계

Go Dashboard는 유일한 browser UI입니다. 제한된 services/context/errors/correlate view를 위한 stateless same-origin server-side adapter입니다. 별도의 64-lowercase-hex client token은 one-time fragment URL로 전달됩니다. Gateway query token과 고정된 workspace project는 server-side에 남습니다. Raw backend query route, telemetry write route, 임의의 project selector 또는 Victoria host port가 없습니다. Terminal `overview` command와 `obs/*.sh` helper가 agent-facing interface로 남습니다.

## Legacy Grafana state

`${COMPOSE_PROJECT_NAME}_grafana-data`라는 volume은 이전 runtime에서 남아 있을 수 있습니다. Active Compose, setup, volume inspection 또는 reset contract가 선언하지 않습니다. Runtime은 이를 claim, relabel, reset, prune 또는 auto-delete하지 않습니다. 수동 migration 또는 backup state로만 취급하세요. 절차는 [`OPERATIONS.md`](./OPERATIONS.md)에 있습니다.

Lifecycle command, storage retention 및 project/volume 점검은 [`OPERATIONS.md`](./OPERATIONS.md)를 참조하세요. App configuration은 [`CONNECT.md`](./CONNECT.md)를 참조하세요.
