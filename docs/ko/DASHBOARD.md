# Dashboard 및 terminal overview

[English](../DASHBOARD.md) · [한국어](./DASHBOARD.md)

Go Dashboard는 repository의 유일한 browser UI입니다. 선택적인 human inspection console이며, 인증된 `obs/*.sh` helper와 terminal overview가 계속 authoritative agent interface입니다.

## Terminal overview

Terminal overview는 Gateway의 제한된 `GET /v1/context` envelope를 표시합니다.

```bash
make overview SERVICE=sample-app MODE=compact LOOKBACK=15m
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --compact --lookback 15m sample-app
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh --json --since 1h sample-app
```

허용되는 lookback은 정확히 `5m`, `15m`, `1h`, `6h` 및 `24h`입니다. `30m`은 지원되지 않습니다. Overview는 business metric, orders ratio, p95 latency 또는 특정 backend result shape를 보장하지 않습니다. 하나의 failure에 대해서는 evidence에서 32-hex trace ID를 가져와 credential runner를 통해 `./obs/correlate.sh <trace-id>`를 사용하세요.

## Browser Dashboard 시작

안정적인 checkout-owned lifecycle은 Make 전용입니다.

```bash
make dashboard
# open the exact `dashboard bootstrap URL: .../#token=...` line
make dashboard-down
```

`make dashboard`는 checkout의 stable Compose project를 위해 Dashboard service를 강제로 재생성하고, 새로운 cryptographically secure client token을 생성하며, Gateway-backed readiness를 검증하고, 하나의 bootstrap URL을 출력합니다. 기본 host binding은 loopback `http://127.0.0.1:3001`입니다. `DASHBOARD_HOST_PORT`로 의도적인 다른 loopback port를 선택할 수 있습니다. Fragment가 없는 base URL이 아니라 출력된 fragment URL을 여세요. Browser는 fragment를 소비하고 `#overview`로 바꾸며, token을 memory에만 보관하고 Dashboard Authorization header로만 보냅니다. 전체 reload에는 의도적으로 출력된 URL을 다시 열어야 합니다.

Client credential은 정확히 64개의 lowercase hexadecimal character이며 Gateway query token과 다릅니다. Canonical credential file, static asset, HTML, cookie, Web Storage, request query parameter 또는 log에 저장되지 않습니다. Gateway query token과 고정된 workspace project는 server-side에 남습니다. Static asset과 local health는 공개이며, client credential이 없는 `/api/*` request는 일반적인 401을 받습니다.

직접 source Compose를 시작할 때는 유효하고 별개의 token을 직접 제공하세요. Binary는 token endpoint를 노출하지 않습니다.

```bash
export DASHBOARD_CLIENT_TOKEN=<64-lowercase-hex-token>
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile dashboard up -d --build dashboard
# open http://127.0.0.1:3001/#token=$DASHBOARD_CLIENT_TOKEN
```

지원되는 Make 경로를 권장합니다. 이 경로가 project resolution, credential injection, readiness 및 출력되는 bootstrap URL을 소유하기 때문입니다. `make dashboard-down`은 Dashboard service만 중지합니다. `make dev-down`은 telemetry volume을 보존하면서 두 optional profile을 모두 중지합니다.

## 제한된 API

Dashboard는 same-origin server-side adapter입니다. 다음 read route만 노출합니다.

| Route | Method | Bounded input |
| --- | --- | --- |
| `/api/services` | `GET` | No query parameters |
| `/api/context` | `GET` | `service`, `lookback`, and `limit` |
| `/api/errors` | `GET` | `service`, `lookback`, and `limit` |
| `/api/correlate` | `POST` | JSON `trace_id` and optional bounded `limit` |
| `/health` | `GET` | Loopback callers, no query string |
| `/` and `/assets/*` | `GET`, `HEAD` | Embedded, validated assets |

모든 `/api/*` route에는 정확히 하나의 `Authorization: Dashboard <64-lowercase-hex-token>` header가 필요합니다. Unknown 또는 duplicate JSON field, unknown query parameter, invalid service name, invalid lookback, malformed trace ID 및 범위를 벗어난 limit은 Gateway에 연락하기 전에 거부됩니다. Proxy는 고정된 workspace project와 server-side Gateway query credential만 제공합니다. Raw LogQL/PromQL/Jaeger query, telemetry write route, arbitrary backend URL, CORS proxy 또는 browser project selector를 노출하지 않습니다.

Dashboard는 `partial`, `truncated`, no-data 및 backend status state를 evidence로 보존합니다. General visualization 또는 historical time-series product가 아니라 제한된 operating console입니다. Gateway contract는 [`QUERY.md`](./QUERY.md), agent workflow는 shell helper를 사용하세요.

## Runtime hardening

`src/dashboard`는 standard library와 embedded static asset을 사용하는 split-ready Go module입니다. Compose image는 pinned Go builder에서 build되며, builder CA bundle을 포함한 scratch image에서 non-root numeric user로 실행됩니다. Shell/package manager가 없고 writable application volume도 없으며 self-health probe가 있습니다. Dashboard와 Gateway는 dedicated network를 공유하고, app과 Victoria store는 그 network에 참여하지 않습니다. Victoria backend port는 Docker 내부에 남습니다.

Module은 stateless입니다. Telemetry write route, cookie, session, persistent browser state 또는 database가 없습니다. Upstream redirect는 따라가지 않으며 response와 request size가 제한됩니다. Threat model은 [`SECURITY.md`](./SECURITY.md), module build/configuration 상세는 [`../../src/dashboard/README.md`](../../src/dashboard/README.md)를 참조하세요.

## Browser E2E lifecycle

Playwright journey는 stale service를 대상으로 조용히 실행할 수 없도록 의도적으로 Make가 관리합니다.

```bash
make e2e             # demo + Dashboard profiles, complete suite
make e2e-app         # demo profile, sample-app journey only
make e2e-dashboard   # dashboard spec only; starts demo + Dashboard profiles
```

직접 `cd e2e && npm test`를 실행하는 것은 지원되지 않습니다. Make-owned runner는 격리된 project를 선택하고 필요한 label volume을 만들며 profile을 시작하고 app/Gateway/Dashboard evidence를 기다린 뒤 resource를 정리합니다. Dashboard journey는 `dashboard.spec.js`만 선택하더라도 live error와 trace correlation을 실행하므로 demo app이 필요합니다.
