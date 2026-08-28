# Bundled sample app 교체

[English](../REPLACE_SAMPLE_APP.md) · [한국어](./REPLACE_SAMPLE_APP.md)

`src/app` directory는 replaceable demo workload이며 observability backend의 required part가 아닙니다. 다른 service를 관찰하려면 교체할 수 있습니다. 계속 사용하는 profile 또는 browser journey에 필요한 Gateway-only telemetry contract와 lifecycle/readiness contract는 유지하세요.

## 반드시 유지할 것

Application은 다음을 만족해야 합니다.

- Host에서는 `http://127.0.0.1:4318`, Compose edge network에서는 `http://gateway:4318`의 Gateway로 인증된 OTLP/HTTP를 통해 적절한 logs, metrics 및/또는 traces를 emit합니다.
- `http/protobuf`를 사용하고 ingest credential로 `Authorization: Bearer <ingest-token>`을 보내며 query credential은 절대 사용하지 않습니다.
- 서로 다른 `OTEL_SERVICE_NAME`을 설정하고 workspace `agentotel.project.id` resource attribute를 포함합니다.
- Telemetry content를 신뢰하지 않고 bounded 상태로 유지합니다. Credential, request body, personal data 및 secret을 redact하고 high-cardinality metric label을 피합니다.
- Compose `demo` profile로 실행한다면 deterministic health endpoint를 노출합니다. 보통 `GET /health`가 HTTP 200을 반환합니다.
- Dockerfile/build context와 `demo` profile 사용 시 foreground에 머무는 process를 제공합니다.

Gateway, Collector 및 Victoria store가 stack이 소유하는 유일한 telemetry path로 남습니다. Application을 Collector의 internal port 또는 Victoria backend URL로 지정하지 마세요.

## 권장 host process

Compose 외부에서 실행되는 application은 credential과 project scope를 source나 shell history에 두지 않고 inject하도록 launcher를 사용하세요.

```bash
obs setup
obs up
obs run --service my-app -- <application command> [args...]
```

Checkout에서는 source 실행을 명시하세요.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs run --service my-app -- <application command> [args...]
```

Launcher는 `OTEL_SERVICE_NAME`, Gateway endpoint/protocol, URL-encoded ingest header 및 `agentotel.project.id`를 제공하고 child를 시작하기 전에 credential variable을 제거합니다. 다른 application-specific `OTEL_RESOURCE_ATTRIBUTES`는 보존하되 두 번째 project attribute를 추가하지 마세요.

Wrapping이 불가능하면 [`CONNECT.md`](./CONNECT.md)를 따르고 동일한 environment를 명시적으로 설정하세요. Credential은 protected secret source에 보관하세요.

## Compose demo replacement

Bundled service는 `demo` profile로 선택됩니다. 현재 Compose contract에는 다음이 포함됩니다.

```text
OTEL_SERVICE_NAME=sample-app
OTEL_EXPORTER_OTLP_ENDPOINT=http://gateway:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20<ingest-token>
OTEL_RESOURCE_ATTRIBUTES=...agentotel.project.id=<workspace-project-uuid>...
PORT=3000
```

Replacement가 기존 `src/app` layout을 유지한다면 package metadata, lockfile, Dockerfile, source 및 test를 함께 update하세요. Container healthcheck와 Compose mapping이 기대하는 port에서 service가 listen하도록 유지하거나, Compose mapping과 모든 readiness/workload caller를 동일한 변경에서 update하세요. 명시적으로 rebuild합니다.

```bash
make demo
curl -fsS http://127.0.0.1:3000/health
make smoke N=120  # authenticated read-path smoke
```

`workload/run.sh`는 현재 sample route `/api/orders/:id`와 `/api/checkout`을 호출합니다. Generic application protocol이 아닙니다. 이 route를 제거한다면 `obs run`을 자체 workload와 함께 사용하거나 replacement contract의 일부인 workload 및 browser journey를 update하세요. 해당 UI/route 없이 기존 browser E2E suite가 여전히 적용된다고 주장하지 마세요.

## Instrumentation checklist

각 signal에 대해 endpoint가 delivery를 증명한다고 가정하지 말고 application SDK/exporter 동작을 확인하세요.

1. Gateway ingest variable과 project attribute로 app을 시작합니다.
2. 알려진 request 하나와 필요하다면 알려진 error 하나를 생성합니다.
3. Batching/periodic metric export를 기다립니다.
4. Bounded helper를 통해 query합니다.

   ```bash
   obs credentials run -- ./obs/services.sh
   obs credentials run -- ./obs/context.sh my-app 15m 50
   obs credentials run -- ./obs/logs.sh my-app 15m 20
   obs credentials run -- ./obs/traces.sh search-errors my-app 20 1h
   ```

5. Concrete trace ID 하나를 선택하고 `obs correlate <trace-id>`를 실행합니다.
6. Gap을 zero로 채우지 말고 absent signal, `partial`, `truncated` 및 backend status를 기록합니다.

Normal business response에 trace ID를 노출하지 마세요. Bundled demo의 `AGENTOTEL_EXPOSE_TRACE_ID_HEADER=1` opt-in은 controlled local/E2E correlation check에만 사용하며 default로 비활성화되어 있습니다.

## Stack을 교체 가능하게 유지

Replacement app을 수용하기 위해 Gateway route, raw backend access, credential role 또는 project scope를 변경하지 마세요. App은 동일한 authenticated edge 뒤에 있는 하나의 producer이며 query와 Dashboard contract는 bounded 및 service-scoped로 유지됩니다. 보안과 redaction requirement는 [`SECURITY.md`](./SECURITY.md), evidence/completeness limitation은 [`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md)를 참조하세요.
