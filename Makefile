.PHONY: build run debug clean ui-build validate-config validate-config-structure validate-config-access gitea-up gitea-down gitea-logs gitea-reset gitea-seed-pr

APP_NAME := hermit
BIN_DIR := bin
BIN_PATH := $(BIN_DIR)/$(APP_NAME)
GITEA_CONTAINER := hermit-gitea
GITEA_IMAGE := gitea/gitea:1.22.6
GITEA_HTTP_PORT := 3000
GITEA_SSH_PORT := 2222
GITEA_DATA_DIR := ./data/gitea
GITEA_SEED_SCRIPT := ./scripts/seed-gitea-pr.sh
GITEA_TOKEN_SCRIPT := ./scripts/gitea-token.sh

.DEFAULT_GOAL := build

build:
	@mkdir -p $(BIN_DIR)
	go build -o $(BIN_PATH) ./cmd/hermit

run: build
	$(MAKE) ui-build
	./$(BIN_PATH)

debug:
	@command -v air >/dev/null 2>&1 || { echo "air is required. Install with: go install github.com/air-verse/air@latest"; exit 1; }
	@if [ -f .tmp/gitea-token-export.sh ]; then \
		. .tmp/gitea-token-export.sh; \
		echo "Loaded GITEA_TOKEN from .tmp/gitea-token-export.sh for debug session"; \
	fi; \
	if [ -f ui/package.json ]; then \
		if [ ! -d ui/node_modules ]; then \
			echo "Installing UI dependencies..."; \
			cd ui && npm install; \
		fi; \
		(cd ui && npm run dev) & \
		UI_PID=$$!; \
		trap 'kill $$UI_PID 2>/dev/null' EXIT INT TERM; \
		air -c .air.toml; \
	else \
		air -c .air.toml; \
	fi

validate-config:
	go run ./cmd/validate-config --check-access

validate-config-structure:
	go run ./cmd/validate-config

validate-config-access:
	go run ./cmd/validate-config --check-access

ui-build:
	@if [ -f ui/package.json ]; then \
		cd ui && npm run build; \
	else \
		echo "ui/package.json not found, skipping UI build"; \
	fi

clean:
	rm -rf $(BIN_DIR)

gitea-up:
	@mkdir -p $(GITEA_DATA_DIR)
	@if docker ps -a --format '{{.Names}}' | grep -q '^$(GITEA_CONTAINER)$$'; then \
		echo "Starting existing $(GITEA_CONTAINER) container"; \
		docker start $(GITEA_CONTAINER) >/dev/null; \
	else \
		echo "Creating $(GITEA_CONTAINER) container with data dir $(GITEA_DATA_DIR)"; \
			docker run -d \
			--name $(GITEA_CONTAINER) \
			-p $(GITEA_HTTP_PORT):3000 \
			-p $(GITEA_SSH_PORT):22 \
			-v "$(PWD)/data/gitea:/data" \
			-e USER_UID=$$(id -u) \
			-e USER_GID=$$(id -g) \
			-e GITEA__database__DB_TYPE=sqlite3 \
			-e GITEA__database__PATH=/data/gitea/gitea.db \
			-e GITEA__server__DOMAIN=localhost \
			-e GITEA__server__ROOT_URL=http://localhost:3000/ \
			-e GITEA__server__HTTP_PORT=3000 \
			-e GITEA__security__INSTALL_LOCK=true \
			-e GITEA__service__DISABLE_REGISTRATION=true \
			$(GITEA_IMAGE) >/dev/null; \
	fi
	@$(MAKE) gitea-seed-pr
	@TOKEN_EXPORT=$$(bash $(GITEA_TOKEN_SCRIPT) env); \
		echo "$$TOKEN_EXPORT" > .tmp/gitea-token-export.sh; \
		echo "Gitea token is ready at .tmp/gitea-token.env"
	@echo "Gitea is available at http://localhost:$(GITEA_HTTP_PORT)"
	@echo "Set token in your current shell with: eval \"$$(cat .tmp/gitea-token-export.sh)\""

gitea-down:
	@docker stop $(GITEA_CONTAINER) >/dev/null 2>&1 || true

gitea-logs:
	@docker logs -f $(GITEA_CONTAINER)

gitea-reset:
	@docker rm -f $(GITEA_CONTAINER) >/dev/null 2>&1 || true
	@rm -rf $(GITEA_DATA_DIR)

gitea-seed-pr:
	@bash $(GITEA_SEED_SCRIPT)
