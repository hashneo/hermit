---
title: Hermit API as the Canonical Client Interface for Native Apps
status: Accepted
created: 2026-04-25T00:00:00Z
deciders: Engineering Team
tags: [api, architecture, bonjour, connectivity, gomobile, native]
id: adr-009
project_id: hermit
doc_uuid: c4d5e6f7-0009-4000-8000-100000000009
---

# Context

The Hermit native Swift app (macOS and iPadOS) currently calls GitHub's REST API directly, bypassing the Hermit Go backend entirely. This has produced correctness problems: wrong API endpoints for PR review comments, missing hermit-anchor metadata in comment bodies, and incorrect reply threading. The web UI does not have these problems because it routes all GitHub interactions through the Go backend.

Maintaining a parallel GitHub client in Swift creates ongoing drift risk. Any future change to the server-side GitHub interaction logic (endpoint changes, metadata format, threading strategy) must be manually duplicated in the Swift client.

The Hermit Go backend is small (~15–20 MB compiled), has no CGo or C library dependencies, and can be embedded in a macOS app binary. On iPadOS, Apple's sandbox prohibits binding TCP listening sockets, making in-process server embedding impossible. An iPadOS device can however consume the API from a Mac on the same local network.

# Decision

The Hermit native app will consume the Hermit REST API (`/api/v1/...`) as its primary data interface, not GitHub's API directly.

Three connectivity modes are supported:

1. **Embedded local (macOS):** The Go server runs in-process as a goroutine, compiled into the app via `gomobile bind`. The Swift app starts the server at launch and hits `localhost`.
2. **Local network (iPadOS and macOS):** The Mac advertises the running server via Bonjour (`_hermit._tcp`). The iPad discovers it automatically using `NWBrowser` and connects over the local WiFi network.
3. **Remote:** Both devices are configured with an explicit URL pointing at a shared hosted Hermit server. No Bonjour required.

A new `HermitAPIClient` Swift actor replaces `GitHubAPIClient` as the primary API interface in all views. `GitHubAPIClient` is retained only as a debug/standalone fallback.

# Consequences

## Positive

- Eliminates GitHub API alignment drift between web and native clients in one step.
- hermit-anchor metadata, correct reply threading, and thread resolution are all handled server-side — no duplication in Swift.
- iPad gains a fully correct commenting implementation without needing direct GitHub API access.
- The Bonjour discovery model is zero-configuration for engineers on a local network.
- Remote mode enables a shared team deployment where all devices connect to one server.

## Negative

- macOS app binary increases by ~15–20 MB due to the embedded Go server.
- `gomobile bind` adds a build step that must stay in sync with Go server changes.
- All views that call `appState.makeAPIClient()` require migration to `HermitAPIClient`.
- Local network mode requires both devices to be on the same subnet; VPNs that block multicast will prevent Bonjour discovery.
- The Go server requires three changes before it can be embedded: signal handling removal, configurable file paths, and an exported init/stop interface.

## Neutral

- GitHub remains the source of truth for RFC and PR data (ADR-003). The Hermit server is a proxy and orchestration layer, not a competing data store.
- PAT authentication model is unchanged (ADR-005). Each device stores its own PAT and sends it to the Hermit server as a request header.
- The OpenAPI contract (ADR-007) is unchanged. Native clients consume the same contract as the web UI.

# Alternatives Considered

## Keep Direct GitHub API in Swift and Fix Alignment Manually

Patch `GitHubAPIClient` to match the server's endpoint choices, inject hermit-anchor metadata in Swift, and correct the reply endpoint. Rejected: ongoing maintenance burden. Every future server-side change requires a parallel Swift update.

## Compile Go to WebAssembly for iPad

Run Go server logic in a WKWebView WASM context on iPad, avoiding the TCP socket restriction. Rejected: Go→WASM→Swift bridging is immature, WKWebView WASM support on iOS is constrained, and the approach does not solve iPad→Mac collaboration use cases.

## Use CloudKit as iPad↔Mac Relay

Relay API calls through iCloud/CloudKit so the iPad can reach a Mac server without local network proximity. Rejected for v1: high complexity, CloudKit latency, and entitlement requirements. Not ruled out as a future enhancement for off-network use cases.

# References

- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [ADR-005: Use PAT for Initial GitHub Authentication](./adr-005-use-pat-for-initial-github-authentication.md)
- [ADR-007: OpenAPI-First Hermit API for GitHub Interactions](./adr-007-openapi-first-hermit-api-for-github-interactions.md)
- [RFC-006: Native Swift App Vision and Architecture](../rfcs/rfc-006-native-swift-app-vision-and-architecture.md)
- [RFC-009: iPadOS Reading and Commenting App](../rfcs/rfc-009-ipad-reading-and-commenting-app.md)
- [RFC-013: Multi-Device Server Connectivity](../rfcs/rfc-013-multi-device-server-connectivity.md)