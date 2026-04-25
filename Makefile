.PHONY: build run debug clean ui-build validate-config validate-config-structure validate-config-access gitea-up gitea-down gitea-logs gitea-reset gitea-seed-pr native-build native-build-macos native-build-ipad native-test native-clean native-open gomobile-build dev ipad-deploy

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

# ── Native Swift App (macOS + iPadOS) ─────────────────────────────────────────

NATIVE_DIR        := hermit-native
NATIVE_PROJECT    := $(NATIVE_DIR)/HermitNative.xcodeproj
NATIVE_SCHEME     := HermitNative
NATIVE_BUILD_DIR  := $(NATIVE_DIR)/build
NATIVE_APP_SRC    := $(NATIVE_BUILD_DIR)/Build/Products/Debug/HermitNative.app
NATIVE_APP_DEST   := HermitNative.app
XCODE             := DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild

native-build: native-build-macos native-build-ipad ## Build the native app for macOS and iPad simulator

native-build-macos: ## Build the native app for macOS
	@echo "Building HermitNative for macOS..."
	$(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=macOS" \
		-configuration Debug \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		build | xcpretty 2>/dev/null || $(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=macOS" \
		-configuration Debug \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		build
	@echo "Copying HermitNative.app to project root..."
	@rm -rf $(NATIVE_APP_DEST)
	@cp -R $(NATIVE_APP_SRC) $(NATIVE_APP_DEST)

native-build-ipad: ## Build the native app for iPad simulator
	@echo "Building HermitNative for iPad simulator..."
	$(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=iOS Simulator,name=iPad Pro 13-inch (M4)" \
		-configuration Debug \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		build | xcpretty 2>/dev/null || $(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=iOS Simulator,name=iPad Pro 13-inch (M4)" \
		-configuration Debug \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		build

native-test: ## Run the native app test suite
	@echo "Testing HermitNative..."
	$(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=iOS Simulator,name=iPad Pro 13-inch (M4)" \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		test

native-clean: ## Clean the native app build artifacts
	@echo "Cleaning HermitNative build..."
	rm -rf $(NATIVE_BUILD_DIR) $(NATIVE_APP_DEST)
	$(XCODE) -project $(NATIVE_PROJECT) -scheme $(NATIVE_SCHEME) clean 2>/dev/null || true

native-open: build gomobile-build native-build-macos ## Build Go binary + xcframework + macOS app, then launch
	@pkill -x HermitNative 2>/dev/null || true
	@sleep 0.5
	@open $(NATIVE_APP_DEST)

dev: ## Build macOS + iPad apps, restart macOS app, and push to iPad
	@$(MAKE) build
	@$(MAKE) native-build-macos
	@pkill -x HermitNative 2>/dev/null || true
	@sleep 0.5
	@cp -R $(NATIVE_APP_SRC) $(NATIVE_APP_DEST)
	@open $(NATIVE_APP_DEST)
	@$(MAKE) ipad-deploy

IPAD_UDID        := 00008142-000905D10A11401C
IPAD_DEVICE_ID   := 86A8E39E-99D9-5A95-BD57-EE3DAD48E223
IPAD_APP_BUNDLE  := $(NATIVE_BUILD_DIR)/Build/Products/Debug-iphoneos/HermitNative.app

ipad-deploy: ## Build and push to connected iPad (requires Developer Mode enabled)
	@echo "Building HermitNative for iPad..."
	$(XCODE) \
		-project $(NATIVE_PROJECT) \
		-scheme $(NATIVE_SCHEME) \
		-destination "platform=iOS,id=$(IPAD_UDID)" \
		-configuration Debug \
		-derivedDataPath $(NATIVE_BUILD_DIR) \
		-allowProvisioningUpdates \
		EXCLUDED_SOURCE_FILE_NAMES="HermitServer.xcframework" \
		OTHER_SWIFT_FLAGS="-DDEBUG" \
		build
	@echo "Installing on iPad..."
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
		--device $(IPAD_DEVICE_ID) \
		$(IPAD_APP_BUNDLE)

# ── gomobile xcframework ───────────────────────────────────────────────────────

GOMOBILE_OUT := $(NATIVE_DIR)/HermitNative/HermitServer.xcframework

gomobile-build: ## Compile the Go mobile package into HermitServer.xcframework (auto-installs gomobile if needed)
	@if ! command -v gomobile >/dev/null 2>&1; then \
		echo "gomobile not found — installing..."; \
		go install golang.org/x/mobile/cmd/gomobile@latest; \
	fi
	@DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer gomobile init 2>/dev/null || true
	@echo "Building HermitServer.xcframework via gomobile bind..."
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
	gomobile bind \
		-target macos \
		-o $(GOMOBILE_OUT) \
		hermit/mobile
	@echo "xcframework written to $(GOMOBILE_OUT)"
