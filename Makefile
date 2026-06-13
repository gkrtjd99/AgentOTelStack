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

e2e: ## Run the browser UI journey
	cd e2e && npm install && npm run install-browsers && npm test

ps: ## Show stack status
	docker compose ps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

.PHONY: up down clean logs load e2e ps help
