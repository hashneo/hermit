.PHONY: build run debug clean ui-build validate-config validate-config-structure validate-config-access

APP_NAME := hermit
BIN_DIR := bin
BIN_PATH := $(BIN_DIR)/$(APP_NAME)

.DEFAULT_GOAL := build

build:
	@mkdir -p $(BIN_DIR)
	go build -o $(BIN_PATH) ./cmd/hermit

run: build
	$(MAKE) ui-build
	./$(BIN_PATH)

debug:
	@command -v air >/dev/null 2>&1 || { echo "air is required. Install with: go install github.com/air-verse/air@latest"; exit 1; }
	@if [ -f ui/package.json ]; then \
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
