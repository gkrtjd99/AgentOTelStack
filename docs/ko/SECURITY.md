# 보안 경계

[English](../SECURITY.md) · [한국어](./SECURITY.md)

AgentOTelStack은 동일 사용자 환경의 로컬 개발 stack으로 설계되었습니다. 원격 multi-tenant service가 아닙니다. 로컬 credential store를 읽거나 Docker를 제어하거나 동일 사용자로 실행할 수 있는 process는 stack을 읽거나 변경할 수 있습니다.

## Network 및 authentication

Gateway만 host-facing telemetry edge입니다.

- `127.0.0.1:4318`은 Gateway **ingest** bearer로 OTLP/HTTP ingest를 받습니다.
- `127.0.0.1:17777`은 별도의 **query** bearer로 bounded query request를 받습니다.
- Collector와 Victoria port는 Docker network에만 남으며 application이나 사람이 연결할 대상이 아닙니다.

Canonical 0600 credential JSON에는 정확히 `ingest_token`과 `query_token`이 들어 있습니다. Gateway는 credential이 없으면 거부하고 ingest와 query token이 같으면 거부합니다. `project.id`는 workspace provenance 및 query selection이며 authentication 또는 authorization 경계가 아닙니다. `--global`은 query project filter만 제거하며 credential이나 administration을 global로 만들지 않습니다.

Application ingest에는 `obs run`, query helper에는 credential runner를 사용하세요. Token을 출력하거나 commit하거나 repository `.env`에 넣거나 신뢰할 수 없는 child에게 전달하지 마세요. `grafana_admin_password`가 있는 legacy credential file은 migration input일 뿐입니다. Normalization은 두 Gateway token을 보존하고 retired value를 읽거나 export하거나 출력하거나 재사용하지 않습니다.

## Dashboard client 경계

Go Dashboard는 유일한 browser UI이며 bounded Gateway projection으로 가는 read-only same-origin proxy입니다. Normal startup에는 Gateway query token과 다른, 정확히 64개의 lowercase hexadecimal character인 별도의 `DASHBOARD_CLIENT_TOKEN`이 필요합니다. 지원되는 `make dashboard` 경로는 이를 ephemeral하게 생성하고 Dashboard와 readiness probe에만 전달하며 fragment bootstrap URL로 한 번 출력합니다.

Browser는 fragment를 memory에서 소비하고 scrub한 뒤 relative `/api/*` request에 정확히 하나의 Dashboard Authorization header를 보냅니다. Token은 cookie, Web Storage, query parameter, static asset, HTML, label, volume 또는 log에 저장되지 않습니다. 전체 reload에는 one-time URL이 다시 필요합니다. Static asset과 loopback health는 의도적으로 공개되며, 인증되지 않은 API request는 Gateway에 연락하기 전에 일반적인 401을 사용합니다.

Dashboard는 Gateway query token, ingest bearer, cookie, `Origin` 또는 `Referer`를 절대 전달하지 않습니다. Browser input으로 backend URL, raw query, telemetry write route 또는 임의의 project를 선택할 수 없습니다. Host allowlisting은 추가 hardening이지 client-auth 경계가 아닙니다.

## Telemetry content 및 cardinality

Telemetry는 신뢰하지 않는 content입니다. Emit 전에 secret과 personal data를 redact하고, request body와 credential을 log/span/metric label에서 제외하며, label cardinality를 제한하세요. Gateway는 projection field를 allowlist하고 control character를 제거하지만 일반적인 secrecy engine은 아닙니다.

Collector는 새로 ingest되는 data에서 standalone `url.query` 및 `url.fragment` attribute를 제거하고 `?`/`#` 경계에서 URL text를 자릅니다. 이는 Victoria에 이미 저장된 record를 retroactive rewrite하지 않습니다. 인증된 local sender는 여전히 high-cardinality value를 만들거나 retention을 소진할 수 있습니다. 그런 threat가 중요하다면 더 엄격한 ingest proxy/tenant policy를 사용하세요.

Dashboard image는 pinned scratch, non-root runtime이며 CA bundle과 self-health probe가 있습니다. Active image는 immutable base-image digest를 사용합니다. CI는 Compose build context, Go module, Dockerfile, image provenance 및 secret scan을 검증합니다. 이 검사는 build path를 보호하지만 손상된 동일 사용자 Docker installation을 보호하지는 않습니다.

## Identity, reset 및 legacy state

`${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid` 아래의 stack UUID가 active volume label을 제어합니다. Setup과 reset은 ownership check를 사용하고 symlink 또는 mismatched project를 거부합니다. Guarded destructive boundary만 사용하세요.

```bash
obs reset --all --confirm
```

Pre-Dashboard runtime의 `${COMPOSE_PROJECT_NAME}_grafana-data` volume은 active UI state가 아닙니다. Setup, Compose, inspection 및 reset은 이를 claim, relabel, prune 또는 delete하지 않습니다. 수동 backup/migration state로 취급하고 [`OPERATIONS.md`](./OPERATIONS.md)를 따르세요. 그것이 존재한다고 Grafana가 여전히 실행 중이라고 추론하지 마세요.

## 원격 노출

Gateway, Dashboard, Collector 또는 Victoria port를 의도적인 deployment 설계 없이 loopback 바깥에 publish하지 마세요. 원격 사용이 필요하다면 앞에 TLS/authenticated proxy를 두고, OTLP sender를 제한하고, credential을 보호하고 rotate하며, retention과 redaction policy를 정의하고, Victoria backend API를 private으로 유지하세요. Local bearer token과 loopback binding은 원격 trust model을 대신하지 않습니다.

Release integrity 및 checksum verification은 [`RELEASING.md`](./RELEASING.md), Credential diagnosis는 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)를 참조하세요.
