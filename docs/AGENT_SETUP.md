# Agent setup

[English](./AGENT_SETUP.md) · [한국어](./ko/AGENT_SETUP.md)

This document covers installation of the clone-independent runtime. For
checkout development, use [`DEVELOPMENT.md`](./DEVELOPMENT.md); for operation
after setup, use [`OPERATIONS.md`](./OPERATIONS.md).

## Install an immutable release

A release is a versioned source bundle and a paired SHA-256 asset. Download the
checksum and archive for the same immutable tag, verify the archive before
extracting it, then install from the verified tree. The current release version
is `2.1.0`:

```bash
VERSION=2.1.0
BASE="https://github.com/gkrtjd99/AgentOTelStack/releases/download/v${VERSION}"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz.sha256"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum --check "AgentOTelStack-v${VERSION}.tar.gz.sha256"
else
  shasum -a 256 -c "AgentOTelStack-v${VERSION}.tar.gz.sha256"
fi
tar -xzf "AgentOTelStack-v${VERSION}.tar.gz"
cd "AgentOTelStack-v${VERSION}"
make install VERSION="${VERSION}"
```

`sha256sum --check` is the usual Linux command; `shasum -a 256 -c` is the
portable macOS alternative. A successful checksum proves that the downloaded
archive matches the paired checksum asset. The release tag and hosting
repository remain the provenance boundary; a checksum copied from an untrusted
mirror is not an authenticity proof by itself.

The installer places the selected version below
`${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/`, maintains `current` and
`previous` pointers, and installs the global launcher at
`${XDG_BIN_HOME:-$HOME/.local/bin}/obs`. It copies the runtime assets required by
that launcher, not the checkout's root `Makefile`, ordinary `scripts/`, or
`docs/` as installed operational dependencies. The checkout can therefore be
moved or removed after installation.

MCP is built by default during installation and requires Docker. Use
`make install WITHOUT_MCP=1 VERSION="${VERSION}"` only when the read-only MCP
adapter is deliberately not wanted. The installed binary, when present, is
`${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp`.

## First setup

Run the global launcher from any directory:

```bash
obs setup
obs up
obs doctor
```

`obs setup` creates the local credential store and the four active, labeled
telemetry volumes. The canonical credential file is
`${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials`; it is a regular 0600
file containing exactly the distinct `ingest_token` and `query_token` keys.
Compose receives those roles only in the child process. Do not put either token
in source control or a repository `.env` file.

The stack's workspace project is separate from its Docker stack identity. A
checkout's `.agentotel/project.toml` contains the local UUIDv4 telemetry scope
and is ignored by Git; `obs project ensure` creates or validates it. Preserve
that file separately when replacing a checkout if its telemetry identity must
survive. The stack UUID is stored under
`${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid` and controls volume
labels; it is not replaced by `AGENTOTEL_PROJECT_ID`.

After the core runtime is up, connect an app with
`obs run --service NAME -- COMMAND`, or see [`CONNECT.md`](./CONNECT.md). The
bundled sample app is off in the default runtime; a checkout demo uses the
explicit source path described in [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## MCP scope

The installed MCP adapter is read-only and exposes exactly three tools:
`agentotel_context`, `agentotel_correlate`, and `agentotel_services`. It uses the
Gateway query credential and the project resolved from its workspace. It does
not accept an arbitrary project, backend URL, raw query, command, or telemetry
write. Keep its configuration pointer and credential store private. See
[`CONNECT.md`](./CONNECT.md) for a minimal stdio configuration and
[`SECURITY.md`](./SECURITY.md) for the trust boundary.

## Source checkouts are different

A source checkout deliberately does not override an installed runtime through a
bare `./bin/obs` invocation. Use the explicit source prefix:

```bash
make dev-setup
make demo
# or, for a single source command:
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
```

Do not copy a mutable branch archive into a production-style install. Use a
verified release asset for clone-independent operation and an explicit checkout
for development.

## Next references

- [`OPERATIONS.md`](./OPERATIONS.md) — lifecycle, storage, credentials, and
  legacy-volume handling
- [`QUERY.md`](./QUERY.md) — authenticated bounded reads
- [`SECURITY.md`](./SECURITY.md) — credentials, project identity, and local
  threat model
