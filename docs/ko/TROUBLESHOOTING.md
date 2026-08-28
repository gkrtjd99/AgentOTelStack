# 문제 해결

[English](../TROUBLESHOOTING.md) · [한국어](./TROUBLESHOOTING.md)

설치된 runtime에는 설치된 launcher를 사용하고 checkout command에는 `AGENTOTEL_DEV_MODE=1`을 prefix하세요. Collector나 Victoria port에 직접 연결해 진단하지 마세요. Gateway가 지원되는 경계입니다.

## 첫 대응

Credential을 출력하지 않고 다음 read-only check를 실행하세요.

```bash
obs doctor
obs credentials status
obs project ensure
obs services
obs canary
```

Checkout에서는 이에 대응하는 명시적 command를 사용하세요.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs doctor
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials status
AGENTOTEL_DEV_MODE=1 ./bin/obs project ensure
AGENTOTEL_DEV_MODE=1 ./bin/obs canary
```

Stack이 실행 중이 아니면 `obs up` 또는 `make dev-up`으로 시작하세요. Bundled app이 필요하면 `make demo`를 사용하세요. Default core stack에 `sample-app`이 포함된다고 가정하지 마세요.

## Docker 또는 lifecycle failure

Docker가 실행 중인지, active project가 의도한 것인지 확인하세요.

```bash
obs services
obs doctor
obs storage
```

`doctor`는 Docker volume inspection failure를 unavailable로 보고하고, filesystem space가 부족하면 warning을 내며, stack identity 누락, legacy volume 또는 volume ownership 불일치를 보고합니다. Active stack은 정확히 다음 4개의 persistent volume을 소유합니다.

- `<project>_otelcol-queue`
- `<project>_victorialogs-data`
- `<project>_victoriametrics-data`
- `<project>_victoriatraces-data`

`${COMPOSE_PROJECT_NAME}_grafana-data`라는 volume은 active Dashboard volume이 아닌 legacy state입니다. Normal startup의 일부로 삭제하거나 relabel하지 마세요. Mismatched 또는 legacy volume에는 수동으로 검증된 backup/migration이 필요하며 stack은 의도적으로 이를 자동 migration하지 않습니다.

```bash
obs migrate volumes --confirm
```

Command는 manual boundary를 출력하고 implicit copy를 거부합니다. Repair에 `docker compose down -v`나 광범위한 `docker volume prune`을 사용하지 마세요. Guarded reset만 지원되는 destructive stack reset입니다.

```bash
obs reset --all --confirm
```

Interactive terminal과 현재 stack UUID가 필요합니다. 소유한 runtime resource만 제거하고 관계없는 Docker state는 보존합니다.

## Credential 및 401 response

Ingest와 query에는 별도의 credential이 있습니다. Canonical file은 다음과 같습니다.

```text
${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials
```

이는 정확히 `ingest_token`과 `query_token`을 담은 0600 regular file입니다. Value를 표시하지 않고 status를 확인하세요.

```bash
obs credentials status
obs credentials ensure
```

누락되거나 잘못된 store는 내용이 valid하거나 absent일 때만 `ensure`가 repair합니다. `grafana_admin_password`를 포함한 legacy file은 migration input이며 status/ensure가 이를 normalize하고 해당 값을 폐기합니다. 이는 Dashboard나 Gateway credential이 아닙니다.

Credential을 rotate한 뒤 Compose가 새 pair를 inject하도록 stack을 재시작하세요.

```bash
obs credentials rotate
obs down
obs up
```

Read에는 query credential loader를 사용하세요.

```bash
obs credentials run -- ./obs/services.sh
obs credentials run -- ./obs/errors.sh sample-app 15m 20
```

`127.0.0.1:4318`의 401은 보통 ingest bearer가 없거나 malformed이거나 stale이라는 뜻입니다. `127.0.0.1:17777`의 401은 보통 query bearer가 없거나 malformed이거나 stale이라는 뜻입니다. 한 역할을 다른 역할 대신 사용하지 말고 어느 token도 repository `.env` 또는 source file에 넣지 마세요.

## Service, log, metric 또는 trace가 없음

먼저 unavailable path와 empty projection을 구분하세요.

```bash
obs canary
obs context --service sample-app --lookback 15m
obs errors --service sample-app --lookback 15m --limit 20
```

Canary는 인증된 Gateway health와 services projection을 확인합니다. Empty result는 유효한 `no_data`일 수 있습니다. `partial`, `backend_unavailable`, `backend_decode_error` 및 `timeout`은 불완전한 operational evidence를 나타냅니다. 모든 backend status를 검사하고 lookback을 넓히기 전에 Collector batching과 periodic metric export를 기다리세요.

`sample-app`이 없으면 demo profile을 시작하고 health endpoint를 확인하세요.

```bash
make demo
curl -fsS http://127.0.0.1:3000/health
```

Host application에서는 process에 `OTEL_SERVICE_NAME`, Gateway OTLP/HTTP endpoint, `http/protobuf`, 인증된 `Authorization` header 및 `agentotel.project.id`가 있는지 확인하세요. 권장 방식은 다음과 같습니다.

```bash
obs run --service my-app -- <application command>
```

Service가 log/trace를 emit하면서 metric은 지연되거나 없을 수 있습니다. 누락된 signal을 zero로 바꾸거나 metric label만으로 root cause를 추론하지 마세요.

## 실패한 request의 correlation

Projected error 또는 trace에서 lowercase 32-hex trace ID 하나를 가져와 다음을 실행하세요.

```bash
obs correlate 0123456789abcdef0123456789abcdef
```

Checkout helper path는 다음과 같습니다.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- \
  ./obs/correlate.sh 0123456789abcdef0123456789abcdef
```

Correlation이 `trace_not_stored`를 보고하면 잠시 기다린 뒤 retry하고 retention/lookback을 확인하세요. Span은 있지만 log 또는 metric이 없다면 signal별 limitation을 report하세요. `partial` 또는 `truncated`는 response가 exact completeness claim을 뒷받침할 수 없다는 뜻입니다.

## 짧게 사용하는 Collector debug configuration

`src/otel-collector/config-debug.yaml`은 명시적인 opt-in troubleshooting configuration입니다. Active `docker-compose.yml`은 이를 mount하지 않으며, 일반 application은 계속 Gateway를 통해 인증된 OTLP를 보내야 합니다. Local signal diagnosis를 위해 일시적으로 isolated Collector를 실행한다면 짧은 session 동안만 이 configuration을 사용하세요. Local receiver에서 OTLP를 받고 Victoria store로 fan-out data를 쓰는 대신 basic debug output을 씁니다. Receiver port를 publish하거나 production configuration으로 사용하거나 debug export가 Gateway write path를 증명한다고 결론 내리지 마세요. 진단 후 temporary process를 중지하고 normal Gateway/Collector path로 돌아가세요.

## Dashboard 문제

먼저 지원되는 lifecycle을 사용하세요.

```bash
make dashboard
make dashboard-down
```

`make dashboard`가 출력한 정확한 one-time fragment URL(`#token=...` fragment 포함)을 여세요. Browser는 별도의 64-lowercase-hex client token을 memory에 보관하므로 전체 reload에는 bootstrap URL이 다시 필요합니다. Static asset과 `/health`는 public이지만 `/api/*`에는 다음이 필요합니다.

```text
Authorization: Dashboard <64-lowercase-hex-token>
```

Dashboard 401은 Gateway query token을 browser에 노출한다고 해결되지 않습니다. Readiness가 실패하면 bounded service response를 검사하고 다음을 실행하세요.

```bash
curl -fsS http://127.0.0.1:3001/health
make ps
```

Dashboard startup failure는 대개 client token이 정확히 64개의 lowercase hexadecimal character가 아니거나 Gateway query token과 같거나 fixed workspace project UUID가 누락/invalid인 경우입니다. Direct Compose startup은 필요한 모든 server-side variable을 제공해야 하며 `make dashboard`가 권장됩니다.

## Port 충돌

기본 host binding은 loopback `4318`(OTLP ingest), `17777`(query), `3000`(sample app) 및 `3001`(Dashboard)입니다. Make script는 안전한 다른 host port를 선택할 수 있습니다. Workaround로 backend port를 publish하지 마세요. Compose/Make status output에서 선택된 값을 확인하고 application이 선택된 Gateway ingest port를 가리키게 하세요.

## Disk pressure 및 retention

Local filesystem pressure와 bounded evidence를 모두 점검하세요.

```bash
obs storage
obs disk
obs cardinality sample-app
```

Log와 trace는 최대 7일, metric은 최대 30일을 보존합니다. Log와 trace에는 2 GiB disk cap이 있고 모든 store는 200 MiB minimum free space를 강제하며 metric은 retention 밖의 query를 거부합니다. 이는 upper bound이지 모든 event가 남아 있다는 보장이 아닙니다. High-cardinality application attribute는 storage를 더 빨리 소진할 수 있습니다. ID, request body, credential 및 secret을 metric label과 emitted telemetry에서 제외하세요.

## 설치 runtime과 checkout 불일치

설치된 launcher는 선택된 immutable runtime 아래에서 asset을 해석하며 checkout을 읽지 않습니다. Checkout command는 명시적이어야 합니다.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs ...
```

설치 version을 검사하고 알고 있는 previous runtime으로만 돌아가세요.

```bash
obs runtime list
obs runtime rollback
```

Rollback은 runtime pointer를 변경하고 대응하는 runtime image tag를 선택할 뿐 telemetry data나 credential을 다시 쓰지 않습니다. 설치가 불완전하면 [`AGENT_SETUP.md`](./AGENT_SETUP.md)와 [`RELEASING.md`](./RELEASING.md)의 release checksum 및 installer 안내를 사용하세요.

## Escalation evidence

문제를 보고할 때 command, timestamp, 선택된 project 및 service scope, lookback/limit, exit status와 `doctor`, `canary` 또는 관련 Gateway envelope의 redacted output을 포함하세요. Correlation과 관련되면 trace ID 하나를 포함합니다. Ingest/query/client token이나 raw credential file은 절대 포함하지 마세요.
