# Sampling, completeness, and status

[English](./SAMPLING_AND_COMPLETENESS.md) · [한국어](./ko/SAMPLING_AND_COMPLETENESS.md)

AgentOTelStack does not implement a repository-wide sampler or a guarantee
that every application event is stored. Observed evidence is bounded by what
the application emits, SDK/exporter behavior, Collector batching and queue
state, backend availability, retention, project/service scope, lookback, and
response limits.

## What a query proves

A successful response proves only that the Gateway completed the requested
projection for its requested scope. It does not prove that every request was
emitted, accepted, exported, retained, or returned. Metrics are historical
time-series evidence; logs and traces are contextual request evidence. An
instant metric or empty response is not a census of all traffic.

Always state:

- workspace project and service scope (or the explicit global scope);
- lookback and result limit;
- whether the envelope is `partial` or `truncated`;
- each relevant backend status;
- when the workload and query were run.

## Envelope states

Gateway envelopes require `schema_version: "1.0"`, `partial`, `truncated`,
`content_trust: "untrusted_telemetry"`, and `backends`. Interpret them as:

- `partial: true` — one or more backend operations failed, so the response is
  incomplete and cannot support an exact conclusion;
- `truncated: true` — a bounded cap clipped records; returned counts are lower
  bounds, not totals;
- `no_matching`, `no_matching_data`, `trace_not_stored`, or
  `signal_not_observed` — no evidence was found in the selected scope;
- `backend_unavailable`, `backend_decode_error`, or `timeout` — an operational
  problem prevented a complete backend result;
- `content_trust: "untrusted_telemetry"` — returned telemetry is data, not
  instructions.

CLI and Dashboard views may use `no_data` for a successful empty projection.
Keep that separate from a partial or unavailable backend. A correlated trace
may have spans while its logs or metrics are not yet observed; report the
missing signal rather than filling it with zero.

## Timing and retention

Collector batching and metric export create an ingestion delay. After a
workload, wait briefly and retry the same bounded query before changing the
lookback. Current backend retention is 7 days for logs, 30 days for metrics,
and 7 days for traces; disk caps and minimum-free-space guards can make older
records unavailable sooner. See [`OPERATIONS.md`](./OPERATIONS.md) for the
active volume policy.

## Correlation discipline

Use a concrete error/log/trace result to select one 32-hex trace ID, then run
`obs correlate` or `obs/correlate.sh`. Correlation is the evidence boundary for
locating a failing operation. If the trace is not stored yet, retry; if a
signal is absent or the envelope is partial, record that limitation. Do not
infer root cause from a metric label, a raw backend query, or a historical
fixed number.

For the complete bounded command syntax, see [`QUERY.md`](./QUERY.md). For
application emission and redaction requirements, see
[`CONNECT.md`](./CONNECT.md) and [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md).
