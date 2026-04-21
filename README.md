# Hermit

Hermit is a document-first RFC collaboration application built for GitHub workflows.

It lets teams submit a single RFC markdown file in a pull request, review it in a rich reading experience, and collaborate with inline comments and approvals from the Hermit UI while preserving GitHub as the source of truth.

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
```

Configured repositories are seeded at startup (when their token env var is set), and are available in the UI selection context.

Validate config locally:

```bash
make validate-config
make validate-config-structure
```

- `validate-config` performs full validation (structure + token presence + repository API access).
- `validate-config-structure` checks only file structure and required fields.

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
