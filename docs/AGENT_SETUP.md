# Agent setup

This document is for installing the runtime for an agent or human on a machine.
The installed launcher is self-contained and versioned; it does not require the
source repository to remain checked out.

## Install and start

### Stable release (2.1.0)

Use the immutable GitHub release assets for a reproducible installation. Fetch
the checksum first, then the tarball, verify it before extraction, and install
from the verified source tree:

```bash
VERSION=2.1.0
BASE="https://github.com/gkrtjd99/AgentOTelStack/releases/download/v${VERSION}"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz.sha256"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz"
sha256sum --check "AgentOTelStack-v${VERSION}.tar.gz.sha256"
tar -xzf "AgentOTelStack-v${VERSION}.tar.gz"
cd "AgentOTelStack-v${VERSION}"
make install VERSION="${VERSION}"
```

The `v2.1.0` tag and its assets are immutable: do not replace an asset or
silently reuse a tag. A changed checksum is a different release and should be
investigated before installation. The checksum detects corruption and confirms
the tarball matches the paired release asset; trust the GitHub tag/release (or
an independently verified mirror) for provenance.

For source development, clone the repository (or check out an immutable tag)
and run the checkout launcher with `AGENTOTEL_DEV_MODE=1`. A source checkout
is intentionally different from the clone-independent release runtime. Before
upgrading either one, copy `.agentotel/project.toml` to a safe location and
restore it after the upgrade when the existing telemetry identity must survive.

From a clone, run:

```bash
make install VERSION=2.1.0
obs setup
obs up
obs doctor
```

`make install` creates a 0600 credential store containing distinct Gateway
ingest/query tokens and the Grafana admin password. A source checkout that has
not been installed can initialize the same store with
`./bin/obs credentials ensure` (or `obs setup` does this automatically).
Compose targets load those values in-process; secrets are not printed or
written to a repository `.env` file. Existing `GATEWAY_*`/`GF_*` environment
values remain supported as explicit operator overrides.

Project metadata is generated locally in `.agentotel/` and is ignored by Git.
The local `.agentotel/project.toml` supplies the checkout's telemetry identity;
it is not a shared source artifact. The release checksum protects the downloaded
asset, while this local file preserves identity independently of the release
version. Before upgrading an existing checkout, copy that file somewhere safe
if you need to preserve the same identity, then restore it into the new
checkout's `.agentotel/` directory.

`obs setup` creates and labels the exact persistent volumes. `obs up` starts
the shared six-service runtime: Gateway, collector, queue initializer, and
the three Victoria backends (the sample app is off). For a checkout demo, run
`AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build`.

The launcher and runtime are installed under the XDG agentotel directories and
can be invoked from another directory. Query credentials are read from the
agentotel credential store; keep ingest/query tokens and the Grafana password
out of source control. Query helpers can be run from any checkout with
`./bin/obs credentials run -- ./obs/context.sh my-app`.
See [`CONNECT.md`](./CONNECT.md) for app configuration and MCP setup.

The installed MCP command is `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp`.
It is built for the host OS and architecture and remains usable if this clone is
moved or deleted. Docker is required during installation to build it; use
`make install WITHOUT_MCP=1` only when the MCP capability is intentionally not
wanted.
Launch MCP with the workspace project as its current directory (or provide a
validated `AGENTOTEL_PROJECT_ID` from the workspace launcher). Its three tools
always query that project and do not accept an arbitrary project argument.

## Maintenance and safety

```bash
obs doctor
obs down        # stop, preserve telemetry
obs migrate volumes --confirm # legacy volume: prints manual backup/copy/verify flow
obs reset --all --confirm     # destructive, interactive UUID/project/volume guard
```

`obs storage --json` is a read-only storage and cardinality check. It reports
exact filesystem bytes, retention/disk caps, and bounded 15-minute Gateway
projections for ingest rate, active metric series, log-stream churn, and trace
service/span-name churn. Results are capped at 500 records and preserve
`no_data` versus `backend_unavailable`; they never expose raw backend queries
or fabricate zeroes. Keep run/commit/instance/raw IDs out of metric labels and
log streams (the low-cardinality policy).

The read-only MCP adapter exposes exactly three tools:
`agentotel_context`, `agentotel_correlate`, and `agentotel_services`.

If `doctor` reports `migration_required`, do not delete or auto-convert the
legacy volume. Back it up and follow the manual migration instructions printed
by `obs migrate volumes --confirm`, then verify before switching the runtime.
