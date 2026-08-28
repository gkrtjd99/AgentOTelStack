# Gateway JSON contract (v1)

[English](../JSON_CONTRACT.md) · [한국어](./JSON_CONTRACT.md)

Query Gateway는 `127.0.0.1:17777`에서 listen하며 모든 query와 health request에 query bearer를 요구합니다. 지원되는 projection은 다음과 같습니다.

- `GET /v1/services`
- `GET /v1/context`
- `GET /v1/errors`
- `GET` 또는 strict JSON `POST /v1/correlate`
- 인증된 `GET /v1/health` 및 `GET /v1/version`

Shell helper가 지원되는 client입니다. `--global`을 명시적으로 선택하지 않는 한 workspace project filter를 추가하며 raw backend syntax를 절대 받지 않습니다.

## Envelope

Response는 [`src/gateway/schemas/envelope.schema.json`](../../src/gateway/schemas/envelope.schema.json) 및 `src/gateway/schemas/` 아래의 endpoint reference를 따릅니다. Required field는 다음과 같습니다.

```json
{
  "schema_version": "1.0",
  "data": {},
  "partial": false,
  "truncated": false,
  "content_trust": "untrusted_telemetry",
  "backends": [
    {"name": "logs", "status": "ok"}
  ]
}
```

`data`는 endpoint별로 projection된 object입니다. Bounded response limit에 도달하면 `warnings`가 나타날 수 있습니다. `backends`는 각 signal/backend의 status를 기록하며 bounded safe `error` string을 포함할 수 있습니다. Gateway는 response field를 allowlist하고 control character를 제거하며 oversized response를 거부하고 telemetry text를 신뢰할 수 있는 instruction으로 취급하지 않습니다.

## Input bounds

Gateway는 다음을 검증합니다.

- Query syntax delimiter가 없는 bounded printable value로서의 service name
- Optional UUIDv4 string으로서의 project value
- 정확히 32개의 lowercase hexadecimal character인 trace ID
- `5m`, `15m`, `1h`, `6h` 또는 `24h`인 lookback
- `1`부터 `500`까지의 integer인 limit(생략하면 default `50`)

Unknown query parameter와 unknown JSON field는 거부됩니다. Correlation에는 `trace_id`가 필요합니다. Correlate request body는 strict JSON이며 Gateway parser에 따라 `trace_id`, `project`, `service`, `lookback` 및 `limit`을 포함할 수 있지만, public helper는 trace와 bounded limit만 제공합니다. Dashboard는 proxy하기 전에 browser project override를 거부합니다.

## Status 및 completeness

`partial`은 하나 이상의 backend가 operationally 실패했다는 의미입니다. `truncated`는 bounded response cap이 result를 잘랐다는 의미입니다. `no_matching_data`, `no_matching`, `trace_not_stored` 또는 `signal_not_observed`와 같은 backend status는 요청된 scope 안에서 유효한 absence result이며 `backend_unavailable`, `backend_decode_error` 또는 `timeout`과 같지 않습니다. Response는 항상 `content_trust: "untrusted_telemetry"`를 전달합니다.

Consumer는 completeness를 주장하기 전에 `partial`, `truncated` 및 모든 관련 backend status를 검사해야 합니다. Correlation은 log 또는 metric이 없어도 trace에 대해 성공할 수 있으며, response는 signal별 indicator를 보존합니다. 해석 지침은 [`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md)를 참조하세요.

## Compatibility rule

`schema_version`과 envelope field를 stable contract로 취급하세요. Backend-specific raw field spelling과 query syntax는 의도적으로 stable하지 않습니다. Backend를 우회하지 말고 `docs/QUERY.md`와 bounded helper를 사용하세요.
