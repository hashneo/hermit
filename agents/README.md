# Agents Directory

This directory is reserved for Hermit-specific agent profiles, prompts, and execution helpers.

## Purpose

- Store agent definitions used for project workflows.
- Keep agent-specific guidance separate from product docs in `docs-cms/`.
- Provide a stable location for future multi-agent orchestration assets.

## Suggested Structure

```text
agents/
├── README.md
├── planner/
│   └── AGENT.md
├── implementer/
│   └── AGENT.md
└── reviewer/
    └── AGENT.md
```

## Notes

- Keep architecture and product decisions in `docs-cms/` (PRDs, ADRs, RFCs).
- Use this directory for operational agent behavior, not canonical design decisions.
