# Skills Directory

This directory contains reusable, documented workflows for agents working in the Hermit repository.

## What are Skills?

Skills are standardized playbooks for recurring tasks (for example: docs validation, ADR creation, or pre-PR checks). They help keep agent behavior consistent and reduce ad hoc process drift.

## Available Skills

- **[documentation-validation](documentation-validation/SKILL.md)** - Validate and fix `docs-cms` documents with Docuchango.
- **[adr-management](adr-management/SKILL.md)** - Create/update/supersede ADRs using project conventions.
- **[critical-thinking](critical-thinking/SKILL.md)** - Apply evidence-based analysis to product and architecture proposals.
- **[ci-precheck-commit](ci-precheck-commit/SKILL.md)** - Run local quality checks before commit.
- **[git-checkin](git-checkin/SKILL.md)** - Stage explicit files and create clean commits.
- **[ci-precheck-pr](ci-precheck-pr/SKILL.md)** - Run pre-PR checks and verify branch readiness.
- **[pr-lifecycle](pr-lifecycle/SKILL.md)** - End-to-end PR flow from branch to merge readiness.
- **[pr-resolve](pr-resolve/SKILL.md)** - Address PR review feedback and close threads.
- **[pre-checkin-gate](pre-checkin-gate/SKILL.md)** - Compatibility alias to `ci-precheck-commit`.
- **[pre-pr-gate](pre-pr-gate/SKILL.md)** - Compatibility alias to `ci-precheck-pr`.

## Recommended Next Skills

- `rfc-management/` - Create and refine RFCs linked to ADR/PRD context.
- `api-contract/` - Maintain and validate OpenAPI-first API workflows.
- `ui-helios-conformance/` - Ensure UI decisions align with ADR-006 (Helios).

## Skill Structure

Each skill should live in its own folder:

```text
skills/
└── skill-name/
    └── SKILL.md
```

## SKILL.md Template (Suggested)

```markdown
# <skill-name>

## When to Use

Describe triggers for this skill.

## Workflow

1. Step one
2. Step two
3. Step three

## Verification

- Command(s) to validate outcome

## Related Docs

- Links to PRD/ADR/RFC files in docs-cms
```

## Notes

- Keep skills focused and practical.
- Update skills when project workflows change.
- Reference `docs-cms/` documents for policy and architecture decisions.
