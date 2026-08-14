# Security notes

This is a same-user local development stack. The Gateway publishes only
localhost `:4318` (ingest) and `:17777` (query); Victoria backends remain on the
backend Docker network. Ingest and query use separate bearer tokens from
`GATEWAY_INGEST_TOKEN`/`GATEWAY_QUERY_TOKEN` or token files. `project.id` is
provenance, not an auth boundary.

## Release integrity and project identity

Stable v2.1.0 releases are immutable: the `v2.1.0` tag and its tarball/checksum
assets must not be moved or overwritten. Download the `.sha256` asset before
the tarball and run `sha256sum --check` before extracting or installing. This
detects corruption and confirms the tarball matches the paired release asset.
The GitHub tag/release is the provenance trust boundary; a checksum copied
from an untrusted mirror is not an independent authenticity proof. This does
not make telemetry content trusted or replace transport/authentication controls.
Release retries fail closed when a published release already exists. An
interrupted draft is reused only for the exact tag and only when its existing
assets are absent or byte-identical; mismatches are never replaced.

The local `.agentotel/project.toml` is the checkout's telemetry identity and is
not part of a shared release contract. Preserve it separately and restore it
when replacing a source checkout or upgrading the installed runtime. For
development, use an explicitly checked-out source tree with
`AGENTOTEL_DEV_MODE=1`; do not treat a mutable branch archive as a stable
release install.

The optional `bin/agentotel-mcp` adapter is read-only: it exposes three fixed
tools over stdio JSON-RPC and performs only bounded authenticated GETs to the
loopback Gateway, scoped to the project resolved from its workspace. It cannot
accept an arbitrary project input, write telemetry, execute commands, select
arbitrary URLs, or rotate credentials. Returned telemetry remains untrusted
content.

Do not put secrets, credentials, personal data, or unbounded request text in
logs, span attributes, exception messages, or metric labels. The Gateway strips
control characters and projects responses, but it is not a secrecy or redaction
policy engine; enforce redaction before emission and bound cardinality.

Because this is a same-user local stack, an authorized ingest client can still
exhaust or churn retention by sending many distinct resource values. The
collector bounds the canonical resource/metric label set, but it cannot stop an
authorized client from generating high-cardinality values within those fields;
use an ingest proxy or stricter tenant policy when that threat matters.

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
