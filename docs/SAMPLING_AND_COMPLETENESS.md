# Sampling, completeness, and status

This repository does not implement a sampler. Completeness is limited by what
the app emits, collector batching, backend retention, and the selected scope.
Metrics are historical time-series data; logs and traces are contextual request
evidence. An instant metric is not proof that every request was observed.

Envelopes distinguish `ok`, `partial` (a backend failed), and `truncated` (a
limit clipped results). State conclusions with scope and freshness, and
correlate a concrete trace before claiming a root cause.
