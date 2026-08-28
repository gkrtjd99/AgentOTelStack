# 운영

[English](../OPERATIONS.md) · [한국어](./OPERATIONS.md)

이 문서는 설정이 끝난 뒤 설치된 runtime의 권위 문서입니다. Root [`Makefile`](../../Makefile)은 checkout 편의 계층이지 설치된 operator interface가 아닙니다. Release runtime에는 global `obs` launcher를 사용하세요.

## Lifecycle

```bash
obs setup
obs up
obs doctor
obs services
obs down
```

`obs setup`은 유효한 기존 identity에 대해 idempotent합니다. 0600 credential store를 보장하고, persisted stack UUID를 해석하며, active volume allowlist를 검사하고, stack 및 Compose-project label과 함께 누락된 volume을 생성하며, 생성 후 모든 label을 검증합니다. 안전하지 않거나 일치하지 않는 사전 존재 volume은 relabel하지 않고 거부합니다.

`obs up`은 공유 core인 Gateway, Collector, queue initializer 및 세 Victoria store를 시작합니다. `demo`와 `dashboard` profile은 꺼져 있습니다. `obs run`으로 host application을 연결하세요. Optional browser Dashboard는 [`DASHBOARD.md`](./DASHBOARD.md)에 설명된 checkout-owned Make lifecycle입니다.

`obs down`은 demo 및 Dashboard profile을 중지하고 모든 active telemetry volume을 보존합니다. Reset이나 legacy data migration을 수행하지 않습니다. 실행 중인 stack은 service가 up인 동안에만 data를 계속 받을 수 있고, 보존된 volume은 이미 저장된 data를 유지합니다.

## Credential 및 identity

Canonical file은 `${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials`입니다. 정확히 서로 다른 두 개의 hexadecimal value를 포함하는 일반 0600 file입니다.

```json
{"ingest_token":"…","query_token":"…"}
```

Token 내용을 출력하지 않고 다음 command를 사용하세요.

```bash
obs credentials status
obs credentials ensure
obs credentials rotate
```

Rotation은 두 역할을 atomic하게 교체합니다. 실행 중인 container가 새 값을 받도록 `obs down` 다음 `obs up`으로 Gateway/Compose service를 재시작하세요. `grafana_admin_password`를 함께 가진 pre-Dashboard credential file은 migration input으로만 허용됩니다. Credential command는 두 Gateway token을 유지하고 정상화 중 retired value를 폐기합니다. Retired value는 export, 출력 또는 재사용되지 않습니다.

Stack identity는 `${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid`입니다. 네 개의 active volume에 label을 붙이며 environment override로 조용히 re-key되지 않습니다. Workspace project identity는 다릅니다. Source checkout은 UUIDv4를 `.agentotel/project.toml`에 저장하며, 이 file은 Git에서 ignore되고 query scope와 telemetry provenance를 제공합니다. Project identity를 안정적으로 유지해야 한다면 checkout을 교체할 때 해당 file을 보존하세요.

## Runtime version 및 path

설치된 data root는 `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel`입니다. `current`는 active immutable runtime을 선택하고, `previous`는 새 version이 이전 version을 대체할 때 유지됩니다.

```bash
obs runtime list
obs runtime rollback
```

Rollback command는 launcher pointer를 변경할 뿐 telemetry data를 다시 쓰지 않습니다. Config, data, state 및 runtime directory는 restrictive permission을 가진 private directory여야 합니다. 설치된 launcher는 자체 asset을 해석하므로 source checkout을 이동하거나 삭제해도 선택된 runtime은 바뀌지 않습니다.

## Volume, retention 및 storage 점검

Active volume은 정확히 다음과 같습니다.

- `<compose-project>_otelcol-queue` — Collector persistent queue
- `<compose-project>_victorialogs-data` — VictoriaLogs data
- `<compose-project>_victoriametrics-data` — VictoriaMetrics data
- `<compose-project>_victoriatraces-data` — VictoriaTraces data

현재 Compose retention과 disk policy는 log 7일/2 GiB, metric 30일, trace 7일/2 GiB이며 Victoria store에는 200 MiB minimum free-disk guard가 있습니다. 정확한 backend implementation과 image version은 runtime detail로 남습니다. 직접 backend API 대신 bounded check를 사용하세요.

```bash
obs doctor
obs storage
AGENTOTEL_JSON=1 obs storage
AGENTOTEL_JSON=1 obs cardinality sample-app
AGENTOTEL_JSON=1 obs canary
```

이 점검은 unavailable, no-data, partial 및 warning state를 구분하고 Gateway projection을 사용합니다. Zero를 만들어내거나 raw backend query를 노출하지 않습니다. Low-cardinality service와 metric dimension을 유지하세요. 동일 사용자의 인증된 sender도 과도한 distinct value로 retention을 소진할 수 있습니다.

## Destructive 경계

명시적인 reset command만 destructive합니다.

```bash
obs reset --all --confirm
```

TTY와 정확히 입력한 stack UUID가 필요합니다. 무엇인가를 삭제하기 전에 현재 Compose project를 해석하고, 정확한 allowlist의 ownership label을 검증하고, 해당 project만 중지하고, 외부 container holder를 확인하며, 각 volume 제거 직전에 ownership을 다시 검사합니다. 광범위한 `docker compose down --volumes`를 전달하지 않고 project를 추측하지도 않습니다.

Guarded lifecycle 대신 `docker volume prune`, unscoped Compose command 또는 수동 `rm`을 사용하지 마세요. `obs down`은 preservation 경계이고 `obs reset --all --confirm`은 정확한 reset 경계입니다.

## Legacy volume migration

`${COMPOSE_PROJECT_NAME}_grafana-data`는 retired Grafana runtime의 가능한 artifact입니다. Active Dashboard volume이 아니며 setup, volume inspection, reset 또는 Compose allowlist에 없습니다. Runtime은 이를 claim, relabel, prune, reset 또는 auto-delete하지 않습니다.

Migration command는 의도적으로 refusal과 guidance를 제공합니다.

```bash
obs migrate volumes --confirm
```

안전한 수동 migration은 operator의 결정입니다.

1. Old runtime을 중지하고 어떤 legacy volume과 data가 필요한지 확인합니다.
2. 필요한 각 volume을 별도로 식별한 backup에 snapshot 또는 copy합니다.
3. Source data를 변경하거나 삭제하기 전에 copy를 검증합니다.
4. `obs setup`으로 새 runtime을 시작하면 정확한 active volume이 생성되고 persisted stack UUID와 Compose project로 label됩니다.
5. 문서화된 compatibility path가 있는 data만 import하고, backup 또는 legacy volume을 제거하기 전에 query하고 검증합니다.

어떤 setup, reset 또는 cleanup command도 이 copy/delete 단계를 대신 수행하지 않습니다.

## Source checkout 참고

Checkout에서는 `make dev-setup`, `make demo` 및 `make dev-down`을 사용하거나 개별 command에 `AGENTOTEL_DEV_MODE=1`을 prefix하세요. 이 target들을 설치된 lifecycle로 제시하지 마세요. Checkout-only 경계는 [`DEVELOPMENT.md`](./DEVELOPMENT.md), health 및 migration diagnosis는 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)를 참조하세요.
