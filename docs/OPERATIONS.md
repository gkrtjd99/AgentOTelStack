# Operations

[English](./OPERATIONS.md) · [한국어](./ko/OPERATIONS.md)

This is the authority for the installed runtime after setup. The root
[`Makefile`](../Makefile) is a checkout convenience layer, not the installed
operator interface. Use the global `obs` launcher for a release runtime.

## Lifecycle

```bash
obs setup
obs up
obs doctor
obs services
obs down
```

`obs setup` is idempotent for a valid existing identity. It ensures the 0600
credential store, resolves the persisted stack UUID, inspects the active volume
allowlist, creates missing volumes with both stack and Compose-project labels,
and verifies every label after creation. It refuses unsafe or mismatched
pre-existing volumes instead of relabeling them.

`obs up` starts the shared core: Gateway, Collector, queue initializer, and the
three Victoria stores. The `demo` and `dashboard` profiles are off. Attach a
host application with `obs run`; the optional browser Dashboard is a
checkout-owned Make lifecycle described in [`DASHBOARD.md`](./DASHBOARD.md).

`obs down` stops the demo and Dashboard profiles and preserves all active
telemetry volumes. It does not perform a reset or migrate legacy data. A
running stack may continue to receive data only while its services are up;
retained volumes preserve already stored data.

## Credentials and identity

The canonical file is
`${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials`. It is a regular 0600
file with exactly two distinct hexadecimal values:

```json
{"ingest_token":"…","query_token":"…"}
```

Use these commands without printing token contents:

```bash
obs credentials status
obs credentials ensure
obs credentials rotate
```

Rotation atomically replaces both roles. Restart the Gateway/Compose services
with `obs down` followed by `obs up` so running containers receive the new
values. A pre-Dashboard credential file that also contains
`grafana_admin_password` is accepted only as migration input; the credential
commands retain the two Gateway tokens and discard the retired value during
normalization. The retired value is never exported, printed, or reused.

The stack identity is `${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid`.
It labels the four active volumes and is never silently re-keyed by an
environment override. Workspace project identity is different: a source
checkout stores its UUIDv4 in `.agentotel/project.toml`, which is ignored by
Git and supplies query scope and telemetry provenance. Preserve that file when
replacing a checkout if the project identity must remain stable.

## Runtime versions and paths

The installed data root is `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel`.
`current` selects the active immutable runtime and `previous` is retained when a
new version replaces an older one:

```bash
obs runtime list
obs runtime rollback
```

The rollback command changes the launcher pointer; it does not rewrite
telemetry data. The config, data, state, and runtime directories are expected
to be private directories with restrictive permissions. The installed launcher
resolves its own assets, so moving or deleting the source checkout does not
change the selected runtime.

## Volumes, retention, and storage checks

The active volumes are exactly:

- `<compose-project>_otelcol-queue` — Collector persistent queue
- `<compose-project>_victorialogs-data` — VictoriaLogs data
- `<compose-project>_victoriametrics-data` — VictoriaMetrics data
- `<compose-project>_victoriatraces-data` — VictoriaTraces data

Current Compose retention and disk policy is 7 days/2 GiB for logs, 30 days for
metrics, and 7 days/2 GiB for traces, with a 200 MiB minimum free-disk guard on
Victoria stores. The exact backend implementation and image versions remain
runtime details; use the bounded checks rather than direct backend APIs:

```bash
obs doctor
obs storage
AGENTOTEL_JSON=1 obs storage
AGENTOTEL_JSON=1 obs cardinality sample-app
AGENTOTEL_JSON=1 obs canary
```

These checks distinguish unavailable, no-data, partial, and warning states and
use the Gateway's projections. They do not invent zeroes or expose raw backend
queries. Keep low-cardinality service and metric dimensions; a same-user
authorized sender can still consume retention with excessive distinct values.

## Destructive boundaries

Only the explicit reset command is destructive:

```bash
obs reset --all --confirm
```

It requires a TTY and an exact typed stack UUID. Before removing anything it
resolves the current Compose project, verifies ownership labels on the exact
allowlist, stops only that project, checks for outside container holders, and
re-inspects ownership immediately before each volume removal. It never passes a
broad `docker compose down --volumes` and never guesses a project.

Do not substitute `docker volume prune`, an unscoped Compose command, or a
manual `rm` for the guarded lifecycle. `obs down` is the preservation boundary;
`obs reset --all --confirm` is the exact reset boundary.

## Legacy volume migration

`${COMPOSE_PROJECT_NAME}_grafana-data` is a possible artifact of the retired
Grafana runtime. It is not an active Dashboard volume and is not in the setup,
inspection, reset, or Compose allowlists. The runtime will not claim, relabel,
prune, reset, or auto-delete it.

The migration command is intentionally a refusal plus guidance:

```bash
obs migrate volumes --confirm
```

A safe manual migration is an operator decision:

1. Stop the old runtime and confirm which legacy volumes and data are needed.
2. Snapshot or copy each needed volume to a separately identified backup.
3. Verify the copy before changing or deleting any source data.
4. Start the new runtime with `obs setup`, which creates the exact active
   volumes and labels them with the persisted stack UUID and Compose project.
5. Import only data that has a documented compatibility path, then query and
   verify it before removing the backup or legacy volume.

No setup, reset, or cleanup command performs those copy/delete steps for you.

## Source checkout note

For a checkout, use `make dev-setup`, `make demo`, and `make dev-down`, or prefix
individual commands with `AGENTOTEL_DEV_MODE=1`. Do not present those targets as
the installed lifecycle. See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for the
checkout-only boundary and [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) for
health and migration diagnosis.
