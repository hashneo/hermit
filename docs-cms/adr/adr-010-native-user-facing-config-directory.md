---
title: User-Facing Config Directory for the Native App
status: Proposed
created: 2026-07-01T00:00:00Z
deciders: Engineering Team
tags: [architecture, config, distribution, native]
id: adr-010
project_id: hermit
doc_uuid: 0b357ad2-daac-4b6d-ba71-bd7f77b9505d
---

# Context

The Hermit native app (macOS/iPadOS) currently has no user-facing config location. Configuration reaches the app through three channels, none of which work for distributing a shared account/repository catalog to teammates running a **binary build**:

1. **Build-time embed** — `make native-embed-config` copies `config/hermit.yaml` + the Gitea token into `DevConfig/` inside the signed app bundle. Read-only, developer-only, and debug-only.
2. **Source-checkout discovery** — `GiteaAutoConfig` walks up from the app bundle (or a security-scoped bookmark) to find a directory containing `config/hermit.yaml`. Developer-only; a binary user has no checkout.
3. **Manual entry** — accounts and repositories typed into the in-app UI, persisted in `UserDefaults`/Keychain.

A team operating many GitHub repositories (e.g. the 60-repo `hermit-repos.meridian.json` catalog spanning `github.com` and `github.ibm.com`) cannot realistically hand-type every account and repository on every teammate's machine. Baking that catalog into the build is wrong: it couples internal endpoints to the shipped binary, and it still would not let a binary user *update* the catalog without a rebuild.

The app already uses `~/Library/Application Support/Hermit/` as the embedded Go server's data directory (`EmbeddedServerManager.appSupportDirectory()`). Application Support is the conventional macOS location for user/sandbox-accessible app data, and the native app runs non-sandboxed (confirmed by `scripts/seed-native-prefs.py` writing the non-sandboxed prefs path).

# Decision

Establish a **user-facing config directory** at:

```text
~/Library/Application Support/Hermit/config/
```

A new `SharedConfigStore` reads every `hermit-repos*.json` file dropped there on launch and upserts the catalog (accounts + repositories) into `AccountStore` and `RepositoryStore`.

Catalog format (existing `hermit-repos.meridian.json` schema):

```json
{
  "version": 1,
  "accounts": [{ "id": "github", "name": "github.com", "endpoint": "https://api.github.com" }],
  "repositories": [{ "account": "github", "owner": "jrepp", "name": "merge-god",
                     "docs_path": "docs-cms/rfcs", "rfc_label": "hermit:rfc-ready" }]
}
```

Key properties:

- **Tokens are never in the file.** Each user adds their own PAT per account via the UI; it is stored in Keychain (release) or `UserDefaults` (debug), keyed by the account's stable UUID. This keeps the catalog safe to share over plain channels.
- **Stable, derived UUIDs.** Each account's UUID is derived deterministically from its string `id` (UUIDv3/MD5). Reloading or updating the catalog is idempotent and never orphans a saved token.
- **Merge, not replace.** Existing user-added accounts/repositories are preserved; the catalog is layered on top. Repositories are matched by `accountID + owner + name` to preserve UUIDs.
- **Build-time wiring removed.** The meridian catalog is no longer referenced by any build/seed step. It lives only in the user-facing directory and is gitignored from the repo.

Distribution: a catalog author commits or shares the JSON out-of-band; teammates drop it into `~/Library/Application Support/Hermit/config/` and relaunch.

# Consequences

## Positive

- Binary users get a populated account/repo list without a source checkout, a rebuild, or manual entry.
- Catalogs are shareable, diffable text files with no secrets.
- Updating a team's catalog is a file copy + relaunch — no app rebuild.
- Decouples internal endpoints (e.g. `github.ibm.com`) from the shipped binary.

## Negative

- Adds one new launch-time filesystem read (cheap; no-op when the directory is absent).
- Introduces a second source of account/repo definitions (catalog file + user edits); resolved by merge-with-stable-UUID semantics.
- iPadOS users on a sandboxed build cannot reach this path from the Finder; they obtain catalogs via the Mac relay (`replaceAll(fromMDNS:)`) or a future in-app importer. This ADR targets macOS non-sandboxed binary builds first.

## Neutral

- GitHub remains source of truth for RFC/PR data (ADR-003). The catalog only describes *which* accounts/repos to register with the embedded Hermit server.
- The PAT model (ADR-005) is unchanged; the catalog simply does not contain PATs.

# Alternatives Considered

## Bake the Catalog Into the Build (`DevConfig/`)

Rejected: couples internal endpoints to the shipped binary, requires a rebuild to update, and the catalog author explicitly does not want it in the build.

## In-App "Import…" Button (One-Shot Into UserDefaults)

A file picker that imports a catalog once into `UserDefaults`. Rejected as the primary mechanism: not re-applicable on update, not discoverable as a convention, and does not match the existing "Application Support is Hermit's data home" pattern. Could be added later as a convenience on top of the convention directory.

## Keep the Catalog in `config/` and Add It to the Build

Rejected: the catalog references internal (`github.ibm.com`) endpoints and must not ship inside the binary or live in the shared repo.

# References

- [ADR-003: GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [ADR-005: PAT for Initial GitHub Authentication](./adr-005-use-pat-for-initial-github-authentication.md)
- [ADR-009: Hermit API as Canonical Native Client Interface](./adr-009-hermit-api-as-canonical-native-client-interface.md)