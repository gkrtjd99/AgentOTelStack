# Convenience targets. `make help` lists them.
.DEFAULT_GOAL := help

up: ## Start shared infra only (collector + 3 stores) — point your own apps at :4318
	docker compose up -d

demo: ## Start infra + the bundled sample app (profile: demo)
	docker compose --profile demo up -d --build

down: ## Stop the stack
	docker compose --profile demo down

clean: ## Stop + wipe stored telemetry
	docker compose down -v

logs: ## Tail collector + app logs
	docker compose logs -f otel-collector app

load: ## Generate synthetic workload (make load N=500)
	./workload/run.sh $(or $(N),300)

smoke: ## Run end-to-end stack smoke test (make smoke N=120)
	./scripts/smoke.sh $(or $(N),120)

dashboard: ## Show a terminal dashboard / overview (make dashboard SERVICE=sample-app MODE=compact LOOKBACK=15m)
	@./obs/overview.sh $(if $(MODE),--$(MODE),) $(if $(LOOKBACK),--lookback $(LOOKBACK),) $(or $(SERVICE),sample-app)

grafana: ## Start optional Grafana dashboard UI at http://localhost:3001
	docker compose --profile dashboard up -d grafana

grafana-down: ## Stop optional Grafana dashboard UI
	docker compose --profile dashboard stop grafana
	docker compose --profile dashboard rm -f grafana

e2e: ## Run the browser UI journey
	cd e2e && npm install && npm run install-browsers && npm test

ps: ## Show stack status
	docker compose ps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

.PHONY: up down clean logs load smoke dashboard grafana grafana-down e2e ps help
