# Hermit

Hermit is a document-first RFC collaboration application built for GitHub workflows.

It lets teams submit a single RFC markdown file in a pull request, review it in a rich reading experience, and collaborate with inline comments and approvals from the Hermit UI while preserving GitHub as the source of truth.

## Getting Started

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Go | 1.22+ | `brew install go` |
| Xcode | 16+ | Required for native app builds |
| Docker | any | Required for local Gitea |
| Node.js | 18+ | Required for web UI |
| Air | latest | `go install github.com/air-verse/air@latest` |

### Zero-to-demo (recommended)

The `make dev` target does everything in one command — starts Gitea, seeds test data, installs the PAT to Keychain, builds the Go server, builds and launches the macOS app, and deploys to a connected iPad if configured.

```bash
make dev
```

After it completes:

- Gitea runs at `http://localhost:3000`
- Hermit server runs at `http://localhost:8080`
- HermitNative.app is open on macOS

#### First-run notes

On a fresh checkout, run these once before `make dev`:

```bash
cd ui && npm install
cd ..
open -a Docker
```

`make dev` uses full Xcode from `/Applications/Xcode.app`, even if
`xcode-select` points at Command Line Tools. The macOS app can build with
ad-hoc signing and an empty `HERMIT_TEAM_ID`; physical iPad deployment still
requires an Apple Development certificate and a provisioned device.

If Homebrew Python is broken or too new for local plist handling, use the
default repo path:

```bash
make dev PYTHON=/usr/bin/python3
```

This is also the Makefile default.

If `make dev` prints `IPAD_UDID not set — skipping iPad deploy`, the macOS app
was still built and launched. Configure `.local.mk` only when you want to deploy
to a connected physical iPad.

---

### Manual Setup

#### 1. Start local Gitea

```bash
make gitea-up
```

Seed a test repo and review-ready PR:

```bash
make gitea-seed-pr
```

Load the generated token into your shell:

```bash
eval "$(cat .tmp/gitea-token-export.sh)"
```

#### 2. Build and run the Go server

```bash
make build
HERMIT_PAT=$(cat .tmp/gitea-token.env | cut -d= -f2) bin/hermit serve
```

For live-reload development (Go + React hot reload):

```bash
make debug
```

#### 3. Build the macOS native app

```bash
make native-build-macos
```

Seed config into UserDefaults so the app starts pre-configured:

```bash
make native-seed-prefs
```

Open the app:

```bash
open HermitNative.app
```

Or build and launch in one step:

```bash
make native-open
```

---

### Xcode

If you prefer to build and run from Xcode rather than the command line:

#### Open the project

```bash
open hermit-native/HermitNative.xcodeproj
```

Or in Xcode: **File → Open** and select `hermit-native/HermitNative.xcodeproj`.

#### Configure signing (one time)

1. In the Project Navigator select **HermitNative** (top of the tree)
2. Select the **HermitNative** target → **Signing & Capabilities** tab
3. Under **Signing**, check **Automatically manage signing**
4. Set **Team** to your Apple ID or developer team
5. Change the **Bundle Identifier** to something unique e.g. `com.yourname.hermit-native`

> For simulator-only builds no paid developer account is needed — a free personal team works.

#### Create a local config file (one time)

Xcode needs a `Local.xcconfig` to know your bundle ID:

```bash
cp hermit-native/Local.xcconfig.example hermit-native/Local.xcconfig
```

Edit `Local.xcconfig` and set `HERMIT_BUNDLE_ID` to match what you set in signing above.

#### Select a destination and run

1. In the toolbar, click the destination picker (next to the scheme name)
2. Under **iOS Simulators** pick **iPad Pro 13-inch (M4)** (or any iPad simulator)
3. Press **⌘R** to build and run

To run on a physical iPad:

1. Connect the iPad via USB
2. Accept the **Trust This Computer** prompt on the device
3. Enable **Developer Mode**: Settings → Privacy & Security → Developer Mode
4. Select the device in the Xcode destination picker
5. Press **⌘R** — Xcode will sign, install and launch automatically

#### Seed config into the running simulator

After the first launch, the app needs server config. Run this once after `make gitea-up`:

```bash
make native-seed-prefs
```

Then relaunch the app from Xcode (**⌘R**) or the simulator home screen.

---

### iPad Simulator

#### Create a simulator (one time)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl create \
  "iPad Pro 13-inch (M4)" \
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
```

List available runtimes and device types if you need a different model:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list runtimes
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devicetypes | grep iPad
```

#### Boot the simulator

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl boot <UDID>
open -a Simulator
```

#### Build and deploy to simulator

```bash
# Build for simulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project hermit-native/HermitNative.xcodeproj \
  -scheme HermitNative \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -configuration Debug \
  -derivedDataPath hermit-native/build \
  EXCLUDED_SOURCE_FILE_NAMES="HermitServer.xcframework" \
  OTHER_SWIFT_FLAGS="-DDEBUG" \
  build

# Install on simulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl install \
  <UDID> \
  hermit-native/build/Build/Products/Debug-iphonesimulator/HermitNative.app

# Launch
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl launch \
  <UDID> \
  me.steven.hermit-native
```

Or use the Makefile shortcut (builds and deploys by simulator name):

```bash
make native-build-ipad
```

#### Re-deploy after code changes

```bash
# Rebuild
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project hermit-native/HermitNative.xcodeproj \
  -scheme HermitNative \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -configuration Debug \
  -derivedDataPath hermit-native/build \
  EXCLUDED_SOURCE_FILE_NAMES="HermitServer.xcframework" \
  OTHER_SWIFT_FLAGS="-DDEBUG" \
  build

# Reinstall and relaunch
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl install <UDID> \
  hermit-native/build/Build/Products/Debug-iphonesimulator/HermitNative.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl launch <UDID> me.steven.hermit-native
```

---

### Physical iPad

Requires an Apple Developer account and a provisioned device.

#### One-time setup

1. Enable **Developer Mode** on the iPad: Settings → Privacy & Security → Developer Mode
2. Trust this Mac when prompted on the device
3. Copy the local config template:

```bash
cp .local.mk.example .local.mk
```

4. Edit `.local.mk` and set:

```makefile
IPAD_UDID      = <device UDID from Xcode → Devices and Simulators>
IPAD_DEVICE_ID = <same UDID>
```

#### Deploy

```bash
make ipad-deploy
```

This builds a signed Debug IPA and installs it via `devicectl`.

---

### Useful Make targets

| Target | Description |
|--------|-------------|
| `make dev` | Full zero-to-demo: Gitea + server + macOS app + iPad deploy |
| `make debug` | Live-reload: Air (Go) + Vite (React) |
| `make native-build` | Build for macOS and iPad simulator |
| `make native-build-macos` | Build macOS app only |
| `make native-build-ipad` | Build iPad simulator app only |
| `make native-open` | Build everything and launch macOS app |
| `make native-test` | Run Swift test suite |
| `make native-clean` | Remove build artifacts |
| `make ipad-deploy` | Build and deploy to physical iPad |
| `make gitea-up` | Start local Gitea container |
| `make gitea-seed-pr` | Seed test repo and PR |
| `make gitea-down` | Stop Gitea container |
| `make gitea-reset` | Destroy Gitea container and data |
| `make validate-config` | Validate hermit.yaml (structure + token + API access) |
| `make reset` | Full reset: kills app, destroys Gitea, wipes build artifacts |

---

## Vision

Hermit is designed to make RFC review feel like Google Docs-style collaboration with GitHub-native governance.

Key capabilities:

- Single-file RFC pull request validation.
- Markdown rendering from the PR head branch.
- Inline anchored comments with thread lifecycle management.
- Approval actions from Hermit UI.
- Synchronization of comments and review state with GitHub.

## Architecture at a Glance

- Backend: Go monolith.
- API: OpenAPI-first Hermit platform API.
- UI: React web application.
- Design system: HashiCorp Helios.
- Source of truth: GitHub PR state.
- Auth (initial): GitHub Personal Access Tokens (PAT).

## Repository Structure

- `docs-cms/` - Product and architecture documentation (PRD, ADRs, RFCs)
- `go.mod` - Go module definition

## Documentation

Project planning and architecture decisions live in `docs-cms/`.

Core documents:

- `docs-cms/prd/prd-001-hermit-rfc-collaboration-vision.md`
- `docs-cms/adr/adr-001-golang-base-application.md`
- `docs-cms/adr/adr-002-single-monolith-application.md`
- `docs-cms/adr/adr-003-github-source-of-truth.md`
- `docs-cms/adr/adr-004-rfc-doc-source-and-format.md`
- `docs-cms/adr/adr-005-use-pat-for-initial-github-authentication.md`
- `docs-cms/adr/adr-006-adopt-hashicorp-helios-design-system.md`
- `docs-cms/adr/adr-007-openapi-first-hermit-api-for-github-interactions.md`
- `docs-cms/rfcs/rfc-001-hermit-high-level-design-and-architecture.md`
- `docs-cms/rfcs/rfc-002-repository-configuration-and-pat-authentication.md`
- `docs-cms/rfcs/rfc-003-openapi-platform-api-and-github-abstraction.md`
- `docs-cms/rfcs/rfc-004-react-web-ui-with-helios-and-hermit-api.md`

## Working with docs-cms

Use Docuchango to validate and manage docs:

```bash
docuchango validate --verbose
```

If you need help with docs-cms workflows:

```bash
docuchango bootstrap --guide agent
```

## Registry Configuration

Hermit loads runtime config from `config/hermit.yaml` by default.

- Example file: `config/hermit.example.yaml`
- Default local file committed for development: `config/hermit.yaml`
- Optional override path: `HERMIT_CONFIG_FILE=/path/to/hermit.yaml`

Registry entries allow multiple GitHub endpoints with token env references:

```yaml
environment: development
listen_address: ":8080"
registries:
  - name: github-public
    kind: github
    base_url: https://api.github.com
    token_env_var: GITHUB_TOKEN
  - name: github-enterprise
    kind: github
    base_url: https://github.example.com/api/v3
    token_env_var: GHE_TOKEN
  - name: gitea-local
    kind: github
    base_url: http://localhost:3000/api/v1
    token_env_var: GITEA_TOKEN
repositories:
  - owner: hashicorp
    name: hermit
    registry: github-public
    default_branch: main
    docs_path_policy: docs-cms/rfcs/
  - owner: acme
    name: platform-rfcs
    registry: github-enterprise
    default_branch: trunk
    docs_path_policy: docs-cms/rfcs/
  - owner: gitea_admin
    name: hermit-rfcs
    registry: gitea-local
    default_branch: main
    docs_path_policy: docs-cms/rfcs/
```

Configured repositories are seeded at startup (when their token env var is set), and are available in the UI selection context.

Validate config locally:

```bash
make validate-config
make validate-config-structure
```

- `validate-config` performs full validation (structure + token presence + repository API access).
- `validate-config-structure` checks only file structure and required fields.

## Local Gitea Testing

Use the built-in Make targets to run a local Gitea instance for integration testing.

```bash
make gitea-up
```

- Web UI: `http://localhost:3000`
- SSH: `localhost:2222`
- Persistent data directory: `./data/gitea/`

Additional commands:

```bash
make gitea-seed-pr # (re)seed repo + review-ready PR
make gitea-logs   # stream container logs
make gitea-down   # stop container
make gitea-reset  # remove container and delete ./data/gitea/
```

Convenience scripts at repo root:

```bash
./run.sh           # gitea-down -> gitea-up (with retry/delay) -> make run
./run.sh --debug   # gitea-down -> gitea-up (with retry/delay) -> make debug (Air + Vite)
./ren.sh --debug   # alias for ./run.sh --debug
./stop.sh          # make gitea-down
./stop.sh --reset  # make gitea-down && make gitea-reset
```

To use Gitea with Hermit config, set `GITEA_TOKEN` and use registry base URL `http://localhost:3000/api/v1`.

After `make gitea-up`, set your current shell token with:

```bash
eval "$(cat .tmp/gitea-token-export.sh)"
```

`make gitea-up` now automatically ensures a valid local token and prints an `eval` command you can run to load `GITEA_TOKEN` into your current shell session.

Thread/comment state is now persisted across Hermit restarts at `./data/hermit/threads.json`.

Seed details (`make gitea-seed-pr`):

- Creates admin user: `gitea_admin` / `gitea_admin` (local test only)
- Creates repo: `gitea_admin/hermit-rfcs`
- Pushes main-branch RFC: `docs-cms/rfcs/rfc-001-seeded-main-branch.md`
- Pushes PR branch RFC: `docs-cms/rfcs/rfc-002-seeded-pr-review.md`
- Opens ready-for-review PR from `feat/rfc-002-seeded-pr-review` -> `main`

## Local Debug Mode

Use `make debug` for live-reload development:

- Starts Go backend with Air (`cmd/hermit`) and rebuilds/restarts on backend file changes.
- Starts Vite in `ui/` so UI changes hot-reload automatically.
- Backend runs on configured Hermit address (default `http://localhost:8080`), UI dev server runs on `http://localhost:4173`.

Prerequisites:

```bash
go install github.com/air-verse/air@latest
```

Then run:

```bash
make debug
```

## Current Status

Hermit is currently in planning/design phase with foundational PRD, ADRs, and RFCs in place.
