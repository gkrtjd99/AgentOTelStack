# JSON contract (v1)

`GET`/strict JSON `POST` endpoints `/v1/context`, `/v1/errors`,
`/v1/correlate`, and `/v1/services` run on query port `17777` and require a
query bearer token. Correlate requires a 32-hex trace ID.

Responses follow [`gateway/schemas/envelope.schema.json`](../gateway/schemas/envelope.schema.json)
and endpoint schemas in `gateway/schemas/`. Required fields are
`schema_version`, `data`, `partial`, `truncated`, `content_trust`, and
`backends`; content trust is always `untrusted_telemetry`. Backend failures are
reported with status/error and may make the response partial.
