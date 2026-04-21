---
name: critical-thinking
description: Apply evidence-based reasoning to architecture and product decisions; verify claims and evaluate alternatives.
---

# Critical Thinking Skill

Use this skill when reviewing proposals, ADRs, RFCs, and implementation trade-offs.

## Core Behavior

- Verify important claims against repository docs and current decisions.
- Challenge assumptions explicitly.
- Document trade-offs and alternatives.
- Flag unknowns as open questions instead of treating them as facts.

## Workflow

1. Verify source context:

```bash
ls docs-cms/adr/
ls docs-cms/rfcs/
ls docs-cms/prd/
```

2. Cross-check proposal against existing decisions:

- look for conflicts with accepted/proposed ADRs
- identify missing constraints from PRD requirements

3. Evaluate alternatives:

- preferred approach
- at least one viable alternative
- cost/risk of doing nothing

4. Record risks and unresolved questions in ADR/RFC sections.

5. Validate docs after updates:

```bash
docuchango validate --verbose
```

## Verification

- Proposal includes explicit trade-offs, risks, and alternatives.
- No direct contradictions with existing docs without clear supersession path.

## Related Docs

- `docs-cms/adr/`
- `docs-cms/rfcs/`
- `docs-cms/prd/`
