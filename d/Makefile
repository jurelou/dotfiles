BACKEND_DIR:=backend
FRONTEND_DIR:=frontend


##################################################################
# Development
##################################################################
dev:
	docker compose -f docker-compose-dev.yml up --watch
.PHONY: dev

##################################################################
# Pr0duction
##################################################################
prod:
	docker compose -f docker-compose-prod.yml up -d
.PHONY: prod


##################################################################
# Code formatters
##################################################################
format_frontend:
	@cd $(FRONTEND_DIR) && npm run format

format_backend:
	@cd $(BACKEND_DIR) && uv run ruff format --line-length 88

format: format_frontend format_backend
.PHONY: format

##################################################################
# Linters
##################################################################
lint_backend:
	@cd $(BACKEND_DIR) && uv run ruff check . --fix

lint: lint_backend 
.PHONY: lint