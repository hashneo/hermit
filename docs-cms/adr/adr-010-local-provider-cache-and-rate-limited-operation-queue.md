---
title: Add Local Provider Cache and Rate-Limited Operation Queue
status: Proposed
created: 2026-06-27T14:41:18Z
deciders: Engineering Team
tags: [architecture, cache, github, rate-limiting, reliability]
id: adr-010
project_id: hermit
doc_uuid: 26651111-d1f3-4ef9-89d6-09ded1ef53f6
---

# Context

Hermit presents repository RFC state by reading from GitHub or GitHub-compatible APIs through the Hermit API. As repository counts grow, automatic refresh on app startup and periodic menu refreshes can produce bursts of upstream calls across many repositories.

This creates three problems:

- App startup can hammer GitHub before users interact with any repository.
- Multiple UI surfaces can trigger duplicate reads for the same repository.
- Mutating operations such as comments, reviews, branch updates, and merges currently execute immediately, which gives Hermit no central place to smooth request bursts or react to upstream rate limits.

Hermit already treats GitHub as the source of truth for workflow state per ADR-003, and RFC-003 calls out provider-layer retries, backoff, rate-limit handling, idempotency, and local projections/caches. This ADR makes those reliability behaviors explicit for the native embedded server and future shared server deployments.

# Decision

Hermit will add a server-side provider coordination layer backed by embedded SQLite, with two responsibilities:

1. Persistent repository refresh metadata and cached projections.
2. A rate-limited operation queue for GitHub provider reads and writes.

## Refresh Metadata and Cached Projections

Hermit will persist repository refresh state in a SQLite database named `hermit.db` under the server data directory, alongside existing transitional JSON state such as `repositories.json` and `resolved-threads.json`.

For each repository and refreshable view, Hermit will store:

- `last_successful_refresh_at`
- `last_attempted_refresh_at`
- `last_error_code`
- `last_error_message`
- `etag` or provider cache validators when available
- a cached projection payload for repository RFC summaries and lists

Repository RFC list endpoints may return cached data when the cache is fresh enough. On app startup, menu/popout refreshes must first read cached projections and skip upstream calls until the configured minimum refresh interval has elapsed.

Default v1 policy:

- Repository RFC summary/list freshness TTL: 10 minutes.
- Manual user refresh bypasses the TTL for that repository, but still goes through the provider rate limiter.
- Failed refreshes use a shorter retry floor with exponential backoff and jitter.
- Cached projections are not authoritative. GitHub remains canonical whenever fresh upstream data is fetched.

API responses that use cached data should include cache metadata, either in response fields or headers:

- whether the response came from cache
- when the source data was last successfully refreshed
- when the next automatic upstream refresh is allowed

## Rate-Limited Provider Operation Queue

All GitHub/Git-compatible provider calls made by Hermit services will go through a local operation queue.

The queue will:

- Enforce a token-bucket rate limit per provider host and credential.
- Limit concurrent in-flight provider calls per host.
- Coalesce duplicate refresh reads for the same repository/view while one is already queued or running.
- Prioritize user-initiated writes above background reads.
- Apply upstream `Retry-After`, `X-RateLimit-Remaining`, and reset-time signals when providers expose them.
- Persist enough operation metadata to recover safely from app/server restarts where practical.

Write operations must be idempotent or carry idempotency metadata before being retried automatically. Non-idempotent writes may be queued and rate-limited, but must not be blindly replayed after an ambiguous failure.

The SQLite workset database must not store sensitive information. In particular, it must not store PATs, authorization headers, raw comment bodies, or unpublished RFC draft content. Those values remain in the existing credential and request paths. SQLite stores only working-set metadata and cached provider projections needed to avoid repeated upstream reads.

Initial operation classes:

- Background repository refresh reads.
- User-initiated repository refresh reads.
- Thread/comment create, reply, resolve, unresolve, and delete.
- Review approve/request-changes/dismiss operations.
- Branch update, merge, submit-for-review, and mark-implemented operations.

## Placement

The queue and cache live in the Go server, not the Swift client. Native apps continue to consume the Hermit API as the canonical client interface per ADR-009.

Swift may keep lightweight UI state, but durable refresh metadata and provider throttling belong in the Hermit server because:

- The embedded Mac server serves both macOS and nearby iPad clients.
- Remote/shared deployments need the same protection.
- Provider adapters are already server-side.

## Storage

SQLite is the local working-set database for cache projections and provider operation metadata.

The initial database path is:

- Standalone server: `<data_dir>/hermit.db`
- Embedded macOS server: `<Application Support>/Hermit/hermit/hermit.db`

Existing JSON files may be migrated to SQLite when they contain only non-sensitive working-set data. JSON files containing tokens or other secrets must not be blindly migrated into SQLite.

# Consequences

## Positive

- App startup can render recent repository state without immediately calling GitHub for every repository.
- Background refreshes become bounded and predictable.
- Manual refresh remains possible while still respecting local and upstream rate limits.
- Queueing gives Hermit one place to implement retries, backoff, coalescing, and provider-specific rate-limit behavior.
- Server-side placement protects macOS, iPad, web, and future remote clients consistently.

## Negative

- Users may briefly see stale RFC list data until refresh is allowed or completed.
- Implementation adds persistent state, scheduling, and queue observability complexity.
- Write operations need careful idempotency handling to avoid duplicate comments, reviews, or merges.
- Tests must cover timing behavior, queue ordering, and restart recovery, which is more complex than direct request/response flows.
- Migrating existing JSON state requires care because some current JSON files contain token material and are not eligible for the non-sensitive SQLite workset.

## Neutral

- GitHub remains the canonical source of truth; local cache entries are projections.
- Cache TTL and queue policy should be configurable for development, embedded local use, and shared server deployments.
- A future webhook integration can invalidate cache entries sooner, but does not remove the need for startup cache reads and rate limiting.

# Alternatives Considered

## Client-Side Swift Cache Only

Rejected because it would protect only the local native UI. It would not help web clients, iPad clients using a Mac server, or future remote deployments. It would also duplicate provider knowledge outside the Go API boundary.

## Rely Only on GitHub Rate-Limit Responses

Rejected because it allows Hermit to create request bursts before the upstream API pushes back. Local smoothing is needed to avoid unnecessary errors, latency spikes, and throttling.

## Cache Only RFC Lists Without a Queue

Rejected because reads are only part of the problem. Comments, reviews, branch updates, and merges also need a central provider coordination path so retries and rate-limit behavior are consistent.

## Queue Writes Only

Rejected because startup and menu refresh traffic is read-heavy. Without read throttling and coalescing, Hermit can still hammer provider APIs before the user performs any write operation.

## Continue Using JSON Files as the Working-Set Database

Rejected because ad hoc JSON files make it harder to query, expire, coalesce, and inspect cache and queue records. SQLite gives Hermit transactional updates, indexes, and a single durable workset without introducing an external database server.

# References

- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [ADR-009: Hermit API as the Canonical Client Interface for Native Apps](./adr-009-hermit-api-as-canonical-native-client-interface.md)
- [RFC-003: OpenAPI Platform API and GitHub Abstraction](../rfcs/rfc-003-openapi-platform-api-and-github-abstraction.md)
- [RFC-005: Label-Driven PR RFC Discovery and Commentability](../rfcs/rfc-005-label-driven-pr-rfc-discovery-and-commentability.md)
