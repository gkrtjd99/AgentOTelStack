# Security notes

This is a same-user local development stack. The Gateway publishes only
localhost `:4318` (ingest) and `:17777` (query); Victoria backends remain on the
backend Docker network. Ingest and query use separate bearer tokens from
`GATEWAY_INGEST_TOKEN`/`GATEWAY_QUERY_TOKEN` or token files. `project.id` is
provenance, not an auth boundary.

The optional `bin/agentotel-mcp` adapter is read-only: it exposes three fixed
tools over stdio JSON-RPC and performs only bounded authenticated GETs to the
loopback Gateway. It cannot write telemetry, execute commands, select arbitrary
URLs, or rotate credentials. Returned telemetry remains untrusted content.

Do not put secrets, credentials, personal data, or unbounded request text in
logs, span attributes, exception messages, or metric labels. The Gateway strips
control characters and projects responses, but it is not a secrecy or redaction
policy engine; enforce redaction before emission and bound cardinality.

A same-user process able to read local credentials or Docker can read/alter the
stack. For remote use add a TLS/authenticated proxy, restrict OTLP senders,
define retention/redaction, and do not expose backend APIs directly. Grafana is
optional and has no logs plugin; script/API access is canonical.

`make down` and `make clean` preserve telemetry volumes. The destructive cleanup boundary is the
interactive, UUID/project/volume-identity guarded `make reset`;
review its exact target before proceeding. Rotate credentials with
`libexec/agentotel/credentials.sh rotate`; `doctor` and uninstall are limited
to agentotel runtime paths.

## Grafana vulnerability waivers

CI always runs the pinned Trivy 0.73.0 image. App and Gateway images have a
zero HIGH/CRITICAL-finding policy. Grafana has only the narrow, time-bounded
waivers in [`security/grafana-trivy-waivers.json`](../security/grafana-trivy-waivers.json):
each entry is an exact CVE/package/installed-version/fixed-version match for
the pinned upstream image digest, and expires within 30 days. CRITICALs,
expired entries, changed packages or image digests, missing upstream/fixed
version/reachability evidence, and any new HIGH fail CI. The complete Trivy
JSON and a residual-finding summary are uploaded as CI artifacts; waivers are
not a blanket `.trivyignore` and do not use `ignore-unfixed`.
