# Convenience targets. `make help` lists them.
.DEFAULT_GOAL := help

setup: ## Create/persist stack identity metadata and missing labeled volumes
	@./bin/obs credentials ensure >/dev/null; uuid="$$(./bin/obs stack-id)"; if ! AGENTOTEL_JSON=1 ./bin/obs doctor >/dev/null; then echo 'setup: refusing to proceed; inspect `make doctor` and follow `make migrate` manual backup guidance' >&2; exit 1; fi; project="$${COMPOSE_PROJECT_NAME:-dev-observability}"; for volume in otelcol-queue victorialogs-data victoriametrics-data victoriatraces-data grafana-data; do name="$${project}_$$volume"; if docker volume inspect "$$name" >/dev/null 2>&1; then stack="$$(docker volume inspect -f '{{ index .Labels "com.agentotel.stack" }}' "$$name")"; owner="$$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$$name")"; if [ "$$stack" != "$$uuid" ] || [ "$$owner" != "$$project" ]; then echo "setup: refusing volume $$name (expected stack=$$uuid project=$$project; found stack=$$stack project=$$owner). Run make migrate for manual backup/copy/verify." >&2; exit 1; fi; else docker volume create --label "com.agentotel.stack=$$uuid" --label "com.docker.compose.project=$$project" "$$name" >/dev/null; fi; done; printf '%s\n' "$$uuid"

install: ## Install an immutable self-contained runtime (VERSION=x.y.z; WITHOUT_MCP=1 to omit MCP)
	./scripts/install.sh $(if $(WITHOUT_MCP),--without-mcp,) $(or $(VERSION),$$(cat VERSION))

uninstall: ## Remove launcher only; telemetry and runtimes remain
	./scripts/uninstall.sh launcher

up: setup ## Start shared infra only (collector + 3 stores) — point your own apps at :4318
	AGENTOTEL_STACK_UUID="$$(./bin/obs stack-id)" ./bin/obs compose up -d

demo: setup ## Start infra + the bundled sample app (profile: demo)
	AGENTOTEL_STACK_UUID="$$(./bin/obs stack-id)" ./bin/obs compose --profile demo up -d --build

down: ## Stop the stack
	./bin/obs compose --profile demo --profile dashboard down

clean: ## Stop the stack (preserves telemetry volumes)
	./bin/obs compose --profile demo --profile dashboard down

doctor: ## Read-only stack health and configuration diagnostics
	AGENTOTEL_JSON=$(or $(JSON),0) ./bin/obs doctor

storage disk cardinality canary: ## Read-only storage/cardinality/canary checks (make storage JSON=1)
	AGENTOTEL_JSON=$(or $(JSON),0) ./bin/obs $@

reset: ## Destructive reset; requires interactive `make reset` confirmation
	./bin/obs reset --all --confirm

migrate: ## Refuse unsafe automatic volume migration; prints manual backup flow
	./bin/obs migrate volumes --confirm

logs: ## Tail collector + app logs
	./bin/obs compose logs -f otel-collector app

load: ## Generate synthetic workload (make load N=500)
	./workload/run.sh $(or $(N),300)

smoke: ## Run end-to-end stack smoke test (make smoke N=120)
	./bin/obs credentials run -- ./scripts/smoke.sh $(or $(N),120)

security-test: ## Run hermetic gateway security/redaction checks
	./scripts/test-security.sh

cardinality-test: ## Run hermetic stream/metric cardinality checks
	./scripts/test-cardinality.sh

identity-test: ## Run hermetic project identity and concurrent-run checks
	bash tests/runtime/identity_concurrency.sh

credentials-test: ## Run hermetic credential-store and Compose injection checks
	bash tests/runtime/credentials_compose.sh

storage-test: ## Run hermetic storage pressure and identity checks
	./scripts/test-storage-pressure.sh

ci-local: ## Run locally available CI parity gates (never mutates stack volumes)
	./scripts/test-ci-local.sh

dashboard: ## Show a terminal dashboard / overview (make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m)
	@./bin/obs credentials run -- ./obs/overview.sh $(if $(MODE),--$(MODE),) $(if $(LOOKBACK),--lookback $(LOOKBACK),) $(or $(SERVICE),sample-app)

grafana: ## Start optional Grafana dashboard UI at http://localhost:3001
	./bin/obs compose --profile dashboard up -d grafana

grafana-down: ## Stop optional Grafana dashboard UI
	./bin/obs compose --profile dashboard stop grafana
	./bin/obs compose --profile dashboard rm -f grafana

e2e: ## Run the browser UI journey
	cd e2e && npm install && npm run install-browsers && npm test

mcp-build: ## Build the read-only MCP stdio adapter for this host
	./scripts/build-mcp.sh bin/agentotel-mcp

mcp-test: ## Test the MCP adapter
	docker run --rm -v "$(PWD)/mcp:/src" -w /src golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd go test ./...

mcp-fmt: ## Format MCP adapter
	docker run --rm -v "$(PWD)/mcp:/src" -w /src golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd gofmt -w *.go

mcp-race: ## Run MCP race tests
	docker run --rm -v "$(PWD)/mcp:/src" -w /src golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd go test -race ./...

ps: ## Show stack status
	./bin/obs compose ps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

.PHONY: setup install uninstall up down clean doctor storage disk cardinality canary reset migrate logs load smoke security-test cardinality-test identity-test credentials-test storage-test ci-local dashboard grafana grafana-down e2e mcp-build mcp-test mcp-race ps help
