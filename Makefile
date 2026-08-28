# Convenience targets. `make help` lists them.
.DEFAULT_GOAL := help

setup: dev-setup ## Repository development setup (installed operations use `obs setup`)
	@:

dev-setup: ## Explicit checkout development setup
	./scripts/make-compose.sh setup

install: ## Install an immutable self-contained runtime (VERSION=x.y.z; WITHOUT_MCP=1 to omit MCP)
	./scripts/install.sh $(if $(WITHOUT_MCP),--without-mcp,) $(or $(VERSION),$$(cat VERSION))

uninstall: ## Remove launcher only; telemetry and runtimes remain
	./scripts/uninstall.sh launcher

up: dev-up ## Repository development stack (installed operations use `obs up`)
	@:

dev-up: dev-setup ## Start shared infra from the checkout
	./scripts/make-compose.sh compose up -d

demo: dev-setup ## Start infra + bundled sample app from the checkout
	./scripts/make-compose.sh compose --profile demo up -d --build

down: dev-down ## Repository development stop (installed operations use `obs down`)
	@:

dev-down: ## Stop the checkout development stack
	./scripts/make-compose.sh compose --profile demo --profile dashboard down --remove-orphans

clean: dev-down ## Stop the stack (preserves telemetry volumes)
	@:

doctor: ## Read-only stack health and configuration diagnostics
	AGENTOTEL_DEV_MODE=1 AGENTOTEL_JSON=$(or $(JSON),0) ./bin/obs doctor

storage disk cardinality canary: ## Read-only storage/cardinality/canary checks (make storage JSON=1)
	AGENTOTEL_DEV_MODE=1 AGENTOTEL_JSON=$(or $(JSON),0) ./bin/obs $@

reset: ## Destructive reset; requires interactive `make reset` confirmation
	AGENTOTEL_DEV_MODE=1 ./bin/obs reset --all --confirm

migrate: ## Refuse unsafe automatic volume migration; prints manual backup flow
	./bin/obs migrate volumes --confirm

logs: ## Tail collector + app logs
	./scripts/make-compose.sh compose logs -f otel-collector app

load: ## Generate synthetic workload (make load N=500)
	./workload/run.sh $(or $(N),300)

smoke: ## Run authenticated Gateway read-path smoke (make smoke N=120)
	./bin/obs credentials run -- ./scripts/smoke.sh $(or $(N),120)

security-test: ## Run hermetic gateway security/redaction checks
	./scripts/test-security.sh

cardinality-test: ## Run hermetic stream/metric cardinality checks
	./scripts/test-cardinality.sh

identity-test: ## Run hermetic project identity and concurrent-run checks
	bash tests/runtime/identity_concurrency.sh

credentials-test: ## Run hermetic credential-store and Compose injection checks
	bash tests/runtime/credentials_compose.sh

compose-project-test: ## Verify Compose demo project identity resolution
	bash tests/runtime/compose_project_identity.sh

image-tags-test: ## Verify runtime-specific local image tags survive rollback
	bash tests/runtime/image_tags_rollback.sh

storage-test: ## Run hermetic storage pressure and identity checks
	./scripts/test-storage-pressure.sh

shell-call-test: ## Verify shell command-count budgets and output contracts
	bash tests/runtime/shell_call_counts.sh

ci-local: ## Run strict local release gates (hosted-only jobs are reported, never mutates stack volumes)
	./scripts/test-ci-local.sh

dashboard: ## Start the Go browser dashboard at http://localhost:3001
	./scripts/make-compose.sh dashboard

dashboard-down: ## Stop the dashboard service while preserving telemetry and core services
	./scripts/make-compose.sh compose --profile dashboard stop dashboard

overview: ## Show the terminal dashboard / overview (SERVICE=sample-app MODE=compact LOOKBACK=15m)
	@AGENTOTEL_DEV_MODE=1 ./bin/obs credentials run -- ./obs/overview.sh $(if $(MODE),--$(MODE),) $(if $(LOOKBACK),--lookback $(LOOKBACK),) $(or $(SERVICE),sample-app)

e2e: ## Run the complete browser suite (demo + dashboard)
	./scripts/run-e2e.sh all

e2e-app: ## Run only the sample-app browser journey (demo profile)
	./scripts/run-e2e.sh app

e2e-dashboard: ## Run only the Go dashboard browser journey (dashboard spec; demo + dashboard profiles)
	./scripts/run-e2e.sh dashboard

mcp-build: ## Build the read-only MCP stdio adapter for this host
	./scripts/build-mcp.sh bin/agentotel-mcp

mcp-test: ## Test the MCP adapter
	docker run --rm -v "$(PWD)/src/mcp:/src" -w /src golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 go test ./...

mcp-fmt: ## Format MCP adapter
	docker run --rm -v "$(PWD)/src/mcp:/src" -w /src golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 gofmt -w *.go

mcp-race: ## Run MCP race tests
	docker run --rm -v "$(PWD)/src/mcp:/src" -w /src golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 go test -race ./...

ps: ## Show stack status
	./scripts/make-compose.sh compose ps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

.PHONY: setup dev-setup up dev-up down dev-down clean doctor storage disk cardinality canary reset migrate logs load smoke security-test cardinality-test identity-test credentials-test image-tags-test storage-test shell-call-test ci-local dashboard dashboard-down overview e2e e2e-app e2e-dashboard mcp-build mcp-test mcp-race ps help
