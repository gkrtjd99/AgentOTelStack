# Query 및 correlation evidence

[English](../QUERY.md) · [한국어](./QUERY.md)

Query는 `http://127.0.0.1:17777`의 Gateway query listener를 통과하는 인증되고 제한된 projection입니다. Helper는 Victoria URL과 backend query language를 의도적으로 숨깁니다. Query token은 0600 credential store에 보관하거나 명시적인 controlled override로 제공하세요. Source control에 복사될 command example에 token을 넣지 마세요.

## 설치된 dispatcher

`obs setup`과 `obs up` 이후 global launcher를 사용하세요.

```bash
obs services
obs context --service my-app --lookback 15m --limit 50
obs errors --service my-app --lookback 15m --limit 20
obs correlate <32-lowercase-hex-trace-id>
```

Dispatcher는 context/errors에 positional service도 받고 각 query command에서 `--global`을 받습니다.

```bash
obs context --global --service my-app --lookback 1h
obs errors --global --service my-app --lookback 1h --limit 100
obs services --global
obs correlate --global <32-lowercase-hex-trace-id>
```

Gateway가 signal별 별도 cap을 노출할 때까지 `obs correlate --limit`은 helper의 고정 limit `100`과 함께만 허용됩니다. 일반 context와 errors limit은 `1`부터 `500`까지의 integer입니다.

## Checkout helper

Source checkout은 명시적인 credential runner를 통해 credential store를 읽어야 합니다.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/services.sh
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh my-app 15m 50
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/logs.sh my-app 15m 20
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/traces.sh search-errors my-app 20 1h
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/correlate.sh <32-lowercase-hex-trace-id>
```

Source helper의 `--global` form은 positional value 앞에 나타나야 합니다. 예를 들면 다음과 같습니다.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/context.sh --global my-app 15m 50
```

Terminal presentation에는 checkout-only overview wrapper를 사용하세요.

```bash
make overview SERVICE=my-app MODE=compact LOOKBACK=15m
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --json --since 1h my-app
```

Overview는 동일한 bounded context envelope를 표현하는 것이며 business-metric contract가 아닙니다. Orders ratio, p95 latency 또는 임의의 time-series panel을 보장하지 않습니다.

## Scope, lookback 및 project

허용되는 Gateway lookback은 정확히 다음과 같습니다.

- `5m`
- `15m`
- `1h`
- `6h`
- `24h`

일반 helper는 현재 workspace의 `.agentotel/project.toml`에서 UUIDv4 하나를 해석하고 이를 `project` query parameter로 추가합니다. 같은 service name을 사용하더라도 여러 local workspace를 분리할 수 있습니다. `--global`은 의도적인 cross-project diagnosis를 위해 해당 filter를 생략하지만 query bearer를 우회하거나 ingest authentication을 바꾸거나 fixed stack을 바꾸거나 lifecycle/administration access를 부여하지 않습니다.

Service name은 query syntax delimiter가 없는 bounded printable text입니다. Trace ID는 정확히 32개의 lowercase hexadecimal character입니다. Gateway는 bounded limit(`1`–`500`)만 받고 unknown query parameter를 거부합니다. Workspace project가 없거나 invalid한 것은 initialization error이지 backend에 data가 없다는 증거가 아닙니다.

## Signal 및 correlation workflow

단일 signal에서 root-cause conclusion을 내리는 대신 staged workflow를 사용하세요.

1. `obs context`(또는 `metrics.sh`)는 service와 lookback에 대한 bounded metric 및 log context를 보여줍니다.
2. `obs errors`/`logs.sh`는 최근 projected error evidence를 보여줍니다. `trace_id`를 찾고, log에는 `span_id`와 `severity_text`도 들어 있을 수 있습니다.
3. `obs errors`/`traces.sh search-errors`는 최근 failing trace evidence를 찾습니다.
4. `obs correlate <trace_id>`(또는 `correlate.sh`)를 실행해 trace, trace-scoped log 및 same-service metric snapshot을 요청합니다.
5. Code를 바꾸기 전에 correlated operation, status, error 및 backend state를 검사합니다. 그런 다음 동일한 workload를 다시 실행하고 scope와 freshness를 비교합니다.

Trace ID가 유효해도 Collector batching과 backend ingestion이 비동기이므로 아직 저장되지 않았을 수 있습니다. Raw backend query로 범위를 넓히지 말고 bounded lookback 안에서 retry하세요.

## Response state

모든 Gateway query response는 `schema_version` `1.0`, `data`, `partial`, `truncated`, `content_trust: "untrusted_telemetry"` 및 `backends` array를 가진 JSON envelope입니다. Backend status는 요청된 scope에 대한 evidence입니다.

- `ok` — Backend query가 완료되었습니다.
- `no_matching`, `no_matching_data` 또는 `trace_not_stored` — 요청된 scope에서 matching evidence가 반환되지 않았습니다. 이는 outage가 아닙니다.
- `signal_not_observed` — Correlation은 완료되었지만 한 signal에 matching record가 없습니다.
- `backend_unavailable`, `backend_decode_error` 또는 `timeout` — operational failure이며 envelope가 `partial`일 수 있습니다.
- `partial: true` — 하나 이상의 backend signal이 실패했으므로 response를 complete로 취급하지 마세요.
- `truncated: true` — Bounded response cap이 result를 잘랐으므로 반환된 row에서 total count를 추론하지 마세요.

CLI/storage와 Dashboard presentation은 성공한 empty response를 `no_data`로 표시할 수 있습니다. 이를 `partial` 또는 `backend_unavailable`과 구분하세요. Transport와 backend status가 `ok`여도 telemetry content는 신뢰하지 않는 evidence입니다.

## 의도적으로 제공하지 않는 것

지원되는 raw LogQL, PromQL, Jaeger, 임의의 backend URL, write route 또는 browser-supplied project selector는 없습니다. 필요한 view가 `services`, `context`, `errors` 또는 `correlate`로 표현되지 않는다면 Gateway를 우회하지 말고 bounded Gateway contract를 확장하세요. Browser inspection에는 bounded Go Dashboard를, agent automation에는 이 helper와 `make overview`를 사용하세요.
