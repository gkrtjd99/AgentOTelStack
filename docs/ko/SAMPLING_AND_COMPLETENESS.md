# Sampling, completeness 및 status

[English](../SAMPLING_AND_COMPLETENESS.md) · [한국어](./SAMPLING_AND_COMPLETENESS.md)

AgentOTelStack은 repository-wide sampler나 모든 application event가 저장된다는 보장을 구현하지 않습니다. 관측된 evidence는 application이 emit한 내용, SDK/exporter 동작, Collector batching 및 queue state, backend availability, retention, project/service scope, lookback 및 response limit에 의해 제한됩니다.

## Query가 증명하는 것

성공한 response는 Gateway가 요청된 scope에 대해 요청된 projection을 완료했다는 것만 증명합니다. 모든 request가 emit, accept, export, retain 또는 return되었다는 것을 증명하지 않습니다. Metric은 historical time-series evidence이고 log와 trace는 contextual request evidence입니다. Instant metric 또는 empty response는 모든 traffic의 census가 아닙니다.

항상 다음을 명시하세요.

- workspace project와 service scope(또는 명시적인 global scope)
- lookback과 result limit
- envelope가 `partial`인지 `truncated`인지
- 각각 관련된 backend status
- workload와 query를 실행한 시간

## Envelope state

Gateway envelope에는 `schema_version: "1.0"`, `partial`, `truncated`, `content_trust: "untrusted_telemetry"` 및 `backends`가 필요합니다. 다음과 같이 해석하세요.

- `partial: true` — 하나 이상의 backend operation이 실패했으므로 response가 incomplete이며 exact conclusion을 뒷받침할 수 없습니다.
- `truncated: true` — bounded cap이 record를 잘랐으므로 반환된 count는 total이 아닌 lower bound입니다.
- `no_matching`, `no_matching_data`, `trace_not_stored` 또는 `signal_not_observed` — 선택한 scope에서 evidence를 찾지 못했습니다.
- `backend_unavailable`, `backend_decode_error` 또는 `timeout` — operational problem으로 complete backend result를 얻지 못했습니다.
- `content_trust: "untrusted_telemetry"` — 반환된 telemetry는 data이지 instruction이 아닙니다.

CLI 및 Dashboard view는 성공한 empty projection에 `no_data`를 사용할 수 있습니다. 이를 partial 또는 unavailable backend와 구분하세요. Correlated trace에 span이 있어도 log나 metric은 아직 관측되지 않을 수 있습니다. 없는 signal을 zero로 채우지 말고 누락된 signal을 report하세요.

## Timing 및 retention

Collector batching과 metric export는 ingest delay를 만듭니다. Workload 후 잠시 기다리고 lookback을 바꾸기 전에 동일한 bounded query를 다시 시도하세요. 현재 backend retention은 log 7일, metric 30일 및 trace 7일입니다. Disk cap과 minimum-free-space guard 때문에 더 오래된 record를 더 일찍 사용할 수 없게 될 수 있습니다. Active volume policy는 [`OPERATIONS.md`](./OPERATIONS.md)를 참조하세요.

## Correlation 규율

구체적인 error/log/trace result를 사용해 하나의 32-hex trace ID를 선택한 다음 `obs correlate` 또는 `obs/correlate.sh`를 실행하세요. Correlation은 failing operation의 위치를 찾는 evidence boundary입니다. Trace가 아직 저장되지 않았다면 retry하고, signal이 없거나 envelope가 partial이면 해당 limitation을 기록하세요. Metric label, raw backend query 또는 historical fixed number에서 root cause를 추론하지 마세요.

완전한 bounded command syntax는 [`QUERY.md`](./QUERY.md), Application emission과 redaction requirement는 [`CONNECT.md`](./CONNECT.md) 및 [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md)를 참조하세요.
