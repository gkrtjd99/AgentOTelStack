# Source checkout에서 개발

[English](../DEVELOPMENT.md) · [한국어](./DEVELOPMENT.md)

Checkout은 설치된 runtime이 아니라 개발 input입니다. Launcher는 checkout file을 조용히 우선하지 않습니다. Checkout-only Make target 또는 명시적인 `AGENTOTEL_DEV_MODE=1` prefix를 사용하세요.

## Checkout 준비 및 실행

Fresh checkout에서는 다음을 실행합니다.

```bash
make dev-setup
make demo
```

`make dev-setup`은 checkout workspace project를 해석하고 credential store를 초기화하며 Make-owned Compose project를 위한 labeled volume을 생성합니다. `make demo`는 공유 core와 loopback port `3000`의 bundled `sample-app`을 시작합니다. Infrastructure만 필요하면 `make dev-up`을 사용하고, `make dev-down` 또는 `make clean`으로 중지하세요(둘 다 telemetry volume을 보존합니다).

Target을 사용할 수 없을 때는 다음 명시적인 source command가 유용합니다.

```bash
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app
AGENTOTEL_DEV_MODE=1 ./bin/obs doctor
```

Source-development claim에 bare `./bin/obs`를 사용하지 마세요. 설치된 운영에는 [`AGENT_SETUP.md`](./AGENT_SETUP.md) 및 [`OPERATIONS.md`](./OPERATIONS.md)에 설명된 `obs setup`, `obs up` 및 기타 global command를 사용합니다.

## Make target

현재 목록은 `make help`로 확인하세요. 중요한 checkout-only target은 다음과 같습니다.

- `make dev-setup`, `make dev-up`, `make demo`, `make dev-down` — setup 및 Compose lifecycle
- `make load N=500` — synthetic workload
- `make smoke N=120` — 인증된 read-path smoke(기본값은 read-only); workload generation이 의도적일 때는 `AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./scripts/smoke.sh --write 120`을 실행
- `make doctor`, `make storage`, `make overview SERVICE=...` — read-only check
- `make dashboard`, `make dashboard-down` — optional Go Dashboard lifecycle
- `make e2e`, `make e2e-app`, `make e2e-dashboard` — Make-managed browser journey
- `make ci-local` — strict local CI/release inventory

`make e2e-dashboard`는 Dashboard spec만 선택하지만 journey가 live sample-app error와 correlation 가능한 trace를 필요로 하므로 `demo`와 `dashboard` profile을 모두 시작합니다. 직접 `cd e2e && npm test`를 실행하는 것은 지원되지 않습니다. 이는 stale service에 실행되고 project/readiness/cleanup contract를 우회할 수 있습니다.

## Code layout

- `src/app/` — bundled Node sample service 및 OTel bootstrap; [`REPLACE_SAMPLE_APP.md`](./REPLACE_SAMPLE_APP.md)의 contract에 따라 교체 가능
- `src/gateway/` — 인증된 OTLP/query Gateway 및 versioned schema
- `src/otel-collector/` — redaction, bounded shaping 및 fan-out config
- `src/dashboard/` — split-ready standard-library Go browser module
- `src/mcp/` — 읽기 전용 stdio adapter
- `obs/` — bounded query helper
- `libexec/agentotel/` — launcher, credential, project, lifecycle 및 query dispatcher
- `workload/` 및 `e2e/` — synthetic traffic 및 Make-managed browser journey

`.agentotel/project.toml`은 local identity metadata이며 의도적으로 공유 source artifact가 아닙니다. Project scope를 유지해야 한다면 checkout 교체 시 별도로 보존하세요.

## 집중 테스트

변경한 module에서 test를 실행하세요. 예시는 다음과 같습니다.

```bash
# Bundled app
(cd src/app && npm ci && npm test)

# Gateway (the CI image is the portable path when Go is unavailable)
(cd src/gateway && go test ./... && go test -race ./... && go build ./...)

# Dashboard
(cd src/dashboard && go test ./... && go test -race ./... && go vet ./... && go build ./...)
```

Repository CI는 toolchain portability를 위해 pinned Docker image를 사용하며 formatting, shell syntax, image provenance, security, identity 및 runtime contract도 검사합니다. Strict local inventory에는 다음을 사용하세요.

```bash
./scripts/test-ci-local.sh
```

Playwright를 직접 호출하지 말고 Make browser target을 실행하세요. Markdown이나 작은 source file이 바뀌었다는 이유로 broad Docker cleanup을 실행하지 말고 테스트하는 target이 소유한 lifecycle을 사용하세요. Hosted live integration은 `RUN_DASHBOARD_E2E=1`을 설정해야 하며, 그렇지 않으면 integration command는 backend-only 성공을 완전한 browser evidence라고 주장하지 않고 실패합니다.

## Code change 관찰

권장 feedback loop는 다음과 같습니다.

```bash
./workload/run.sh 300
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m
# edit the application
AGENTOTEL_DEV_MODE=1 ./bin/obs compose --profile demo up -d --build app
./workload/run.sh 300
AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/metrics.sh sample-app 15m
```

무엇을 바꿀지 결정하기 전에 항상 구체적인 error trace를 correlate하세요. Before/after command output을 agent report 또는 task context에 남기세요.
