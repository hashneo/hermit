---
title: Hermit Vision - RFC PR Collaboration Experience
status: Draft
author: Steven Taylor
created: 2026-04-20T23:55:40Z
target_release: v1.0.0
tags: [collaboration, github, product, rfc]
id: prd-001
project_id: hermit
doc_uuid: 3153e2fa-2287-4d1a-9e25-2e7272547996
---

# Executive Summary

Hermit provides a Google Docs-like review experience for RFC markdown documents using GitHub pull requests as the source of truth. A user submits a single RFC file through a PR branch, and collaborators can read rendered markdown and add contextual comments inline as if they were commenting in a living document.

Hermit maps these comments to GitHub PR comments and tracks their resolution lifecycle so teams can iterate on RFCs quickly while preserving a complete review history in GitHub.

# Problem Statement

Teams often use GitHub PRs to review RFCs, but the native experience is code-centric and can feel awkward for document-first collaboration. It is hard to review long-form markdown as a narrative document, and it is difficult to see or manage discussion threads in a way that feels natural for collaborative writing.

Product, design, and engineering stakeholders need a review workflow that preserves GitHub governance while making RFC feedback feel like Google Docs comments with clear context and resolution status.

# Goals and Objectives

## Primary Goals

- Enable submission of exactly one RFC markdown file per PR through Hermit.
- Render RFC markdown from the PR branch in a polished, document-first reading view.
- Support inline, anchored comments that behave like Google Docs comments.
- Synchronize Hermit comments with GitHub PR comments and resolution status.

## Success Metrics

- Metric 1: 95% of RFC PRs submitted through Hermit contain exactly one markdown file.
- Metric 2: 90% of comments created in Hermit are successfully mirrored to GitHub PR comments.
- Metric 3: 90% of mirrored comment resolution state changes remain consistent between Hermit and GitHub.
- Metric 4: Median comment-to-resolution time improves by 30% compared with baseline PR-only RFC review.

# User Stories

## As an RFC author

- I want to submit one RFC markdown file from a branch as a PR through Hermit.
- So that I can gather structured feedback without losing GitHub traceability.

## As an RFC reviewer

- I want to read properly rendered markdown and leave inline comments tied to exact content.
- So that I can provide clear feedback the author can action quickly.

## As an engineering manager

- I want comments and resolution state in Hermit to match GitHub PR state.
- So that PR merge readiness is transparent and auditable.

## As an approver

- I want to approve the RFC directly from the Hermit GUI.
- So that I can complete review workflow without switching to GitHub.

# Requirements

## Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Hermit must allow RFC submission only when the PR diff contains exactly one markdown file. | Must Have |
| FR-2 | Hermit must render markdown from the PR branch version of the RFC file, not the base branch. | Must Have |
| FR-3 | Reviewers must be able to create inline comments anchored to specific sections, lines, or text ranges in the rendered view. | Must Have |
| FR-4 | Every Hermit comment must create or map to a corresponding GitHub PR comment thread. | Must Have |
| FR-5 | Hermit must display comment threads in context and provide a document-style side panel for navigation. | Should Have |
| FR-6 | Users must be able to resolve and reopen comments from Hermit, with synchronization to GitHub where supported. | Must Have |
| FR-7 | Hermit must reflect GitHub comment updates (new replies, edits, resolution state) within a short sync window. | Should Have |
| FR-8 | Hermit must show merge readiness by surfacing unresolved comment count for the RFC document. | Should Have |
| FR-9 | Approvers must be able to submit GitHub PR approval directly from the Hermit GUI. | Must Have |
| FR-10 | Hermit must display current PR review state (approved, changes requested, pending) and keep it synchronized with GitHub. | Must Have |

## Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-1 | Markdown rendering latency | First render < 2s for RFCs up to 10,000 words |
| NFR-2 | Comment sync reliability | 99.5% successful sync operations over 30 days |
| NFR-3 | Sync freshness | Remote updates visible in Hermit within 10 seconds median |
| NFR-4 | Availability | 99.9% monthly uptime for collaboration features |
| NFR-5 | Security and permissions | GitHub auth scopes limited to required PR and comment operations |

# Design

## User Interface

Hermit presents a document-first layout with:

- A central rendered markdown surface optimized for long-form RFC reading.
- Inline comment markers at anchored positions.
- A comments panel showing open and resolved threads with filters.
- Clear status badges showing sync state and unresolved thread count.

## Technical Architecture

High-level architecture:

- GitHub App or OAuth integration for repository access and PR comment APIs.
- RFC renderer service that fetches markdown content from the PR head commit.
- Comment anchor model that maps rendered content offsets to source locations.
- Bi-directional synchronization service for Hermit thread events and GitHub PR threads.
- Event log for auditability of comment creation, edits, resolution, and sync outcomes.

## Data Model

Core entities:

- RFCDocument: repo, PR number, file path, head SHA, rendered snapshot metadata.
- CommentThread: thread ID, anchor metadata, author, status, linked GitHub thread ID.
- CommentMessage: message body, author, timestamp, source system, edit history.
- SyncEvent: event type, direction, status, retries, error details.

# Out of Scope

- Multi-file RFC submissions in a single PR.
- Non-markdown document formats.
- General code review replacement for non-RFC changes.
- Real-time collaborative editing of the markdown source itself.

# Dependencies

- GitHub authentication and API access for PRs and review comments.
- Markdown rendering pipeline compatible with GitHub-flavored markdown.
- Background job or event-driven infrastructure for comment synchronization.
- Product design input for anchor UX and comment thread discoverability.

# Timeline

| Milestone | Date | Status |
|-----------|------|--------|
| Product Discovery and UX Concept | 2026-05-10 | Not Started |
| Technical Design and API Contract | 2026-05-24 | Not Started |
| MVP Build (Submission, Render, Inline Comments) | 2026-07-01 | Not Started |
| GitHub Sync and Resolution Lifecycle | 2026-07-22 | Not Started |
| Beta with Internal RFC Workflows | 2026-08-12 | Not Started |
| v1.0.0 Launch | 2026-09-02 | Not Started |

# Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Anchor drift when markdown changes significantly between comments | High | Use resilient anchor strategy combining text ranges, line hints, and fuzzy reattachment |
| GitHub API rate limits during high collaboration periods | High | Batch sync operations, apply backoff/retry, and add queue-based throttling |
| Ambiguity between Hermit resolution model and GitHub thread model | Medium | Define canonical state machine and reconciliation rules early in design |
| Reviewer adoption friction compared with native GitHub UI | Medium | Provide low-friction deep links between Hermit threads and GitHub PR threads |

# Open Questions

- Should Hermit enforce a strict single markdown file in the full PR diff, or only among files under an RFC path convention?
- How should Hermit handle force-pushes that invalidate comment anchors?
- What is the canonical owner of resolution state when GitHub and Hermit updates conflict?
- Should anonymous read access be supported for public repositories?

# Appendix

Initial vision statement:

Hermit is an application that allows us to take an RFC document, submit it as a single-file PR, and let GitHub users comment on it as though it was a Google document. Markdown should render from the PR branch, comments should be visible like document comments, and those comments should be tracked in the PR and resolved before merge.
