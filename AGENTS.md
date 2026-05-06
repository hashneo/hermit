# Agent Instructions for Hermit

**IMPORTANT: These instructions should be followed by AI agents working on this project.**

---

## Quick Start

```bash
cat AGENTS.md
ls -la skills/
git status
docuchango validate --verbose
make dev
```

## Core Principles

1. **Documentation is source of truth**
   - Read `docs-cms/` before making architecture or product decisions.
   - Reference specific PRD/ADR/RFC files in responses.

2. **ADR-first for architecture changes**
   - Before major architectural changes: create/update ADR, get human approval, then implement.
   - Keep new ADRs as `Proposed` until approved.

3. **Use skills for repeatable workflows**
   - Prefer workflows in `skills/` over ad hoc process.

4. **GitHub is canonical workflow state**
   - Hermit integrates with GitHub as source of truth for PR comments/reviews.
   - Clients should use Hermit API contracts, not direct GitHub API calls.

## Available Skills

| Skill | Purpose |
|---|---|
| `documentation-validation` | Validate docs with docuchango |
| `adr-management` | Create/update/supersede ADRs |
| `critical-thinking` | Evidence-based proposal analysis |
| `ci-precheck-commit` | Local quality checks before commit |
| `git-checkin` | Explicit staging and clean commits |
| `ci-precheck-pr` | Pre-PR checks and branch readiness |
| `pr-lifecycle` | Create and maintain PRs |
| `pr-resolve` | Address review comments and follow-ups |
| `pre-checkin-gate` | Alias to `ci-precheck-commit` |
| `pre-pr-gate` | Alias to `ci-precheck-pr` |

## Mandatory Rules

### Rule 1: Feature Branch + PR Workflow

- Never commit directly to `main`.
- Create a feature branch for all changes.
- Push branch and open a PR for review.

```bash
git checkout main
git pull
git checkout -b feat/my-change
```

### Rule 2: Explicit File Staging

- Do not use `git add .` or `git add -A`.
- Stage files explicitly.

```bash
git add path/to/file1 path/to/file2
```

### Rule 3: Validate Documentation Changes

- If `docs-cms/` changes, run validation before commit:

```bash
docuchango validate --verbose
```

### Rule 4: Keep Decisions in docs-cms

- Product requirements: `docs-cms/prd/`
- Architecture decisions: `docs-cms/adr/`
- Design/implementation proposals: `docs-cms/rfcs/`

## Architecture Snapshot

Based on current accepted/proposed docs:

- Backend language: Go (`adr-001`)
- Deployment shape: single monolith (`adr-002`)
- Source of truth: GitHub (`adr-003`)
- RFC source path/format: `docs-cms/rfcs/` with Docuchango conventions (`adr-004`)
- Initial GitHub auth: PAT (`adr-005`)
- UI design baseline: HashiCorp Helios (`adr-006`)
- API boundary: OpenAPI-first Hermit API for GitHub interactions (`adr-007`)

See:

- `docs-cms/prd/prd-001-hermit-rfc-collaboration-vision.md`
- `docs-cms/rfcs/rfc-001-hermit-high-level-design-and-architecture.md`
- `docs-cms/rfcs/rfc-003-openapi-platform-api-and-github-abstraction.md`
- `docs-cms/rfcs/rfc-004-react-web-ui-with-helios-and-hermit-api.md`

## Session Completion Checklist

Before ending a work session:

1. Run relevant checks (docs/tests/lint as applicable).
2. Stage explicit files only.
3. Commit with a clear conventional message.
4. Push feature branch.
5. Open/update PR and summarize what changed.

---

**Status**: Active
**Maintained By**: Hermit contributors and agents

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
