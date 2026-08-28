# Gateway JSON contract (v1)

[English](./JSON_CONTRACT.md) · [한국어](./ko/JSON_CONTRACT.md)

The query Gateway listens on `127.0.0.1:17777` and requires the query bearer
for every query and health request. Supported projections are:

- `GET /v1/services`
- `GET /v1/context`
- `GET /v1/errors`
- `GET` or strict JSON `POST /v1/correlate`
- authenticated `GET /v1/health` and `GET /v1/version`

The shell helpers are the supported client. They add the workspace project
filter unless `--global` is explicitly selected and never accept raw backend
syntax.

## Envelope

Responses follow [`src/gateway/schemas/envelope.schema.json`](../src/gateway/schemas/envelope.schema.json)
and the endpoint references under `src/gateway/schemas/`. The required fields
are:

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

`data` is a projected, endpoint-specific object. `warnings` may appear when a
bounded response limit is reached. `backends` records the status of each
signal/backend and may include a bounded safe `error` string. The Gateway
allowlists response fields, strips control characters, rejects oversized
responses, and never treats telemetry text as trusted instructions.

## Input bounds

The Gateway validates:

- service names as bounded printable values without query syntax delimiters;
- project values as optional UUIDv4 strings;
- trace IDs as exactly 32 lowercase hexadecimal characters;
- lookbacks as `5m`, `15m`, `1h`, `6h`, or `24h`;
- limits as integers from `1` through `500` (default `50` when omitted).

Unknown query parameters and unknown JSON fields are rejected. Correlation
requires `trace_id`. A correlate request body is strict JSON and may contain
`trace_id`, `project`, `service`, `lookback`, and `limit` according to the
Gateway parser; the public helper supplies only the trace and bounded limit.
The Dashboard rejects browser project overrides before proxying.

## Status and completeness

`partial` means at least one backend failed operationally. `truncated` means a
bounded response cap clipped the result. A backend status such as
`no_matching_data`, `no_matching`, `trace_not_stored`, or
`signal_not_observed` is a valid absence result inside the requested scope; it
is not the same as `backend_unavailable`, `backend_decode_error`, or `timeout`.
The response always carries `content_trust: "untrusted_telemetry"`.

Consumers must inspect `partial`, `truncated`, and every relevant backend status
before claiming completeness. Correlation can succeed for traces while logs or
metrics are absent; the response preserves those signal-specific indicators.
See [`SAMPLING_AND_COMPLETENESS.md`](./SAMPLING_AND_COMPLETENESS.md) for
interpretation guidance.

## Compatibility rule

Treat `schema_version` and the envelope fields as the stable contract. Backend-
specific raw field spelling and query syntax are intentionally not stable. Use
`docs/QUERY.md` and the bounded helpers rather than reaching around the Gateway.
