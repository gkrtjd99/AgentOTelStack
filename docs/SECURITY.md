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
optional; script/API access remains canonical.

`make down` and `make clean` preserve telemetry volumes. The destructive cleanup boundary is the
interactive, UUID/project/volume-identity guarded `make reset`;
review its exact target before proceeding. Rotate credentials with
`libexec/agentotel/credentials.sh rotate`; `doctor` and uninstall are limited
to agentotel runtime paths.

## Grafana image provenance and vulnerability gate

The optional Grafana image is a reproducible security repack, not an upstream
runtime image. It takes the Grafana 13.1.3 frontend, configuration, license,
and entrypoint from the pinned multi-architecture digest
`sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43`,
while building the server from source commit
`45a27d64b64a82d666b06aa5c5bb3521587edb0d` with the verified archive checksum
`ef2a9c6da7d6c3ffcd910d5aeb1d00f32f9a36ea49035145ae5bbf902f39567d` in
`src/grafana/Dockerfile`. Both Go builders use the pinned Go 1.26.6 image;
the embedded Tempo dependency is rebuilt from v2.10.3 at peeled source commit
`4aeafc237b8d9a8d62e45735131e8a89eb741a00` (archive checksum
`6159f130af77216215137a1033e3f573cc83e7aba69a19d618b521b7ab41d81f`), and
the VictoriaLogs datasource backend is rebuilt from source commit
`bb1f6d7b0ec2bdf943c2d8c27f2cb17004b147e8` (archive checksum
`e748a9aa2f737952b7f02b0e69b671d1608c7ef765413cf1476a247e681a0245`).

The only supported plugin is `victoriametrics-logs-datasource` v0.31.0. Its
frontend/static assets use the pinned release checksum and its Linux backend
comes from the source build; the upstream server binary and bundled plugin
directory are not copied. The frontend release checksum is
`6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b`.
Plugins are loaded only from immutable
`/opt/grafana-plugins`; startup preinstall, plugin administration/catalog,
public-key retrieval, and update checks are disabled.

The release image gate requires zero HIGH or CRITICAL Trivy findings. Any new
finding, changed pinned source or digest, or plugin outside the supported scope
fails the gate.
