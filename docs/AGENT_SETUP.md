# Agent setup

This document is for installing the runtime for an agent or human on a machine.
The installed launcher is self-contained and versioned; it does not require the
source repository to remain checked out.

## Install and start

From a clone, run:

```bash
make install VERSION=2.0.0
make setup
make up
make doctor
```

`make setup` creates and labels the exact persistent volumes. `make up` starts
the shared seven-service runtime: Gateway, collector, queue initializer, and
the three Victoria backends (the sample app is off). Use `make demo` when the
bundled sample app is wanted.

The launcher and runtime are installed under the XDG agentotel directories and
can be invoked from another directory. Query credentials are read from the
agentotel credential store; keep ingest and query tokens out of source control.
See [`CONNECT.md`](./CONNECT.md) for app configuration and MCP setup.

The installed MCP command is `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp`.
It is built for the host OS and architecture and remains usable if this clone is
moved or deleted. Docker is required during installation to build it; use
`make install WITHOUT_MCP=1` only when the MCP capability is intentionally not
wanted.

## Maintenance and safety

```bash
make doctor
make smoke
make down       # stop, preserve telemetry
make clean      # cleanup, preserve telemetry
make migrate    # legacy volume: prints manual backup/copy/verify flow
make reset      # destructive, interactive UUID/project/volume guard
make uninstall  # removes launcher only; runtimes and telemetry remain
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
by `make migrate`, then verify before switching the runtime.
