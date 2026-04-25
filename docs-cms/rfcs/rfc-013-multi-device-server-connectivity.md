---
title: Multi-Device Server Connectivity
status: Accepted
author: Steven Taylor
created: 2026-04-25T00:00:00Z
tags: [bonjour, embedded-server, go, ipad, ipados, macos, native, networking]
id: rfc-013
project_id: hermit
doc_uuid: b3c4d5e6-0013-4000-8000-100000000013
---

# Summary

This RFC defines how the Hermit native app resolves the API server it consumes, supporting three connectivity modes: embedded local (Mac runs the Go server for itself), local network (iPad discovers a Mac running the server via Bonjour), and remote (both devices point at a shared public server URL). The goal is full API parity between macOS and iPadOS without duplicating GitHub API logic in the Swift layer.

# Motivation

The current native Swift app calls GitHub's API directly from the client. This has created alignment drift with the Hermit Go backend: different API endpoints, missing hermit-anchor metadata in comment bodies, and incorrect reply threading. The web UI is correct because it routes all GitHub interactions through the Go backend.

The right fix is to have the native app consume the same Hermit API that the web UI uses, rather than maintaining a parallel GitHub client in Swift. This requires the Go server to be reachable from both macOS and iPadOS in a way that is zero-configuration for engineers on a local network and optionally shareable via a hosted deployment.

# Detailed Design

## Connectivity Modes

`AppState` gains a `ServerMode` enum with three cases:

```swift
enum ServerMode: Codable {
    case embeddedLocal           // Mac: Go server runs in-process, client hits localhost
    case localNetwork            // iPad (or Mac): discovers server via Bonjour
    case remote(url: String)     // Both: explicit public server URL
}
```

The active mode is persisted to the Keychain alongside existing config and drives `makeAPIClient()` in `AppState`.

## Mode 1: Embedded Local (macOS)

On macOS, the Go server is compiled into an `.xcframework` via `gomobile bind` and started as an in-process goroutine when the app launches. Three Go-side changes are required:

1. **Remove signal handling** — replace `syscall.SIGTERM` shutdown with an exported `Stop()` function callable from Swift.
2. **Configurable paths** — config file path and thread store path are passed from Swift at init time (pointing to the app's sandbox `Application Support` directory).
3. **Exported init function** — a `Start(configJSON: String) -> String` function accepts JSON config (baseURL, PAT, owner, repo, etc.) and returns the bound port as a string.

The Swift app calls `HermitServer.Start(...)` on a background thread during `AppDelegate` / `App.init`, waits for the port to be returned, then sets `AppState.baseURL = "http://localhost:\(port)"`.

The Mac also registers a Bonjour service so nearby iPads can discover it (see Mode 2).

## Mode 2: Local Network Discovery (iPadOS and macOS)

### Mac side — advertising

When the embedded server starts, the Swift app registers a Bonjour service:

```swift
import Network

let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.service = NWListener.Service(name: "Hermit", type: "_hermit._tcp")
listener.start(queue: .main)
```

A TXT record carries a `version` field so future clients can verify compatibility.

### iPad side — discovery

`ServerDiscoveryService` uses `NWBrowser` to scan for `_hermit._tcp` on the local network:

```swift
let browser = NWBrowser(for: .bonjour(type: "_hermit._tcp", domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in
    // Resolve each result to host + port
    // Publish discovered servers to AppState
}
browser.start(queue: .main)
```

`AppState` exposes a `@Published var discoveredServers: [DiscoveredServer]` where `DiscoveredServer` holds the resolved hostname, port, and display name. The settings UI (see below) shows these as selectable options.

When a server is selected, `AppState.baseURL` is set to `"http://{host}:{port}"` and the selection is persisted to Keychain so it survives app restarts (the iPad reconnects automatically on next launch).

### Security — Multipeer Pairing Handshake

Local network traffic is HTTP (not HTTPS) for zero-config simplicity. To prevent unauthorised clients on the same WiFi from connecting, access is gated by a per-device bearer token exchanged during a one-time Multipeer Connectivity pairing handshake.

#### Pairing Flow

```text
iPad                                    Mac
  |                                      |
  |-- MCNearbyServiceBrowser discovers ->|
  |                                      |
  |<------- MCInvitation received -------|  (user sees "Steven's iPad wants to connect")
  |                                      |
  |       [User taps Accept on Mac]      |
  |                                      |
  |<========= MCSession established ====>|
  |                                      |
  |<-- { "token": "<random 256-bit>" }---|  (Mac generates, sends over encrypted peer channel)
  |                                      |
  | Store token in Keychain              |  Mac stores token mapped to iPad's MCPeerID
  |                                      |
  |========= MCSession closed ==========>|  (pairing complete, peer channel torn down)
  |                                      |
  |-- HTTP Bearer <token> -------------->|  (all subsequent API calls use HTTP + token)
```

#### Implementation

- **Mac (`PairingAdvertiser`):** `MCNearbyServiceAdvertiser` with service type `hermit-pair`. On invitation received, presents a system-style confirmation alert: *"Steven's iPad wants to connect to Hermit."* On accept, generates a `256-bit` random token via `SecRandomCopyBytes`, sends it as JSON over the `MCSession` data channel, stores `(peerID → token)` in an in-memory map that the Go server middleware checks.
- **iPad (`PairingBrowser`):** `MCNearbyServiceBrowser` with the same service type. Discovers the Mac, sends an invitation, waits for session establishment, reads the token from the received data, stores it in Keychain under `hermit.local-token`.
- **Go server middleware:** A new auth middleware checks the `Authorization: Bearer <token>` header against the in-memory token map for local network mode. Requests without a valid token receive `401`.
- **Token lifetime:** Tokens are persisted to the Mac's Keychain mapped by `MCPeerID` display name. The iPad stores its token in Keychain under `hermit.local-token`. Both survive app restarts — pairing is a one-time gesture. The Mac loads all persisted tokens into its in-memory map at launch so previously paired iPads reconnect automatically without re-pairing.
- **Revocation:** A paired device list in the Server settings tab on Mac shows all currently paired iPads by `MCPeerID` display name, with a "Revoke" button per device.

#### Why Not iCloud Keychain Shared Secret

iCloud Keychain sync would share a token silently across all devices on the same Apple ID — no explicit consent, no per-device revocation. Multipeer pairing gives the Mac owner a visible trust gesture and per-device control, which is the right model for a server accepting inbound connections.

## Mode 3: Remote (macOS and iPadOS)

Both devices are configured with an explicit base URL pointing at a shared hosted deployment of the Hermit Go server. This is entered manually in the Server settings tab.

The PAT and repository config remain per-device (stored in each device's Keychain) and are sent as request headers to the remote server, which uses them to authenticate with GitHub on behalf of the user.

No discovery is involved. The URL is validated on entry by sending a `GET /api/v1/health` request.

## HermitAPIClient (new)

A new `HermitAPIClient` replaces `GitHubAPIClient` as the primary API actor in the Swift app. It calls the Hermit REST API (`/api/v1/...`) rather than GitHub directly. This eliminates all alignment drift in one step:

- Comment creation uses `POST /api/v1/repositories/{id}/pull-requests/{pr}/threads` — hermit-anchor metadata is injected server-side.
- Replies use `POST .../threads/{tid}/reply` — correct `in_reply_to` threading server-side.
- RFC content fetched via `GET /api/v1/repositories/{id}/rfcs/{rfcId}`.
- PR approval via `POST .../review/approve`.

`GitHubAPIClient` is retained only for the debug/standalone path where no Hermit server is available.

## Settings UI

A new **Server** tab is added to `SettingsView`:

```text
┌─────────────────────────────────────────────┐
│  Server                                     │
│  ─────────────────────────────────────────  │
│  Mode   [Embedded] [Local Network] [Remote] │
│                                             │
│  ── Local Network ──                        │
│  Steven's MacBook Pro  192.168.1.42:8080  ◉ │
│  (scanning...)                              │
│                                             │
│  ── Remote ──                               │
│  Server URL  [https://hermit.example.com  ] │
│              [Validate Connection]          │
└─────────────────────────────────────────────┘
```

- **Embedded** tab is only shown on macOS.
- **Local Network** tab shows Bonjour-discovered servers with live scanning indicator. Paired servers show a lock icon; unpaired servers show a "Pair" button that initiates the Multipeer handshake.
- **Remote** tab shows a URL field and a validate button.
- The active server's connection status (green/red dot) is shown in the Account settings tab.

## Entitlements

The following entitlements are required:

| Entitlement | Platform | Reason |
|---|---|---|
| `com.apple.security.network.server` | macOS | Embedded Go server binds a TCP port |
| `com.apple.security.network.client` | macOS + iOS | Outbound HTTP to local/remote server |
| `com.apple.developer.networking.multicast` | iOS | Bonjour service discovery (`NWBrowser`) |
| `NSLocalNetworkUsageDescription` | iOS Info.plist | Required for local network access permission prompt |
| `com.apple.developer.nearby-interaction` | macOS + iOS | Multipeer Connectivity pairing handshake |

# Drawbacks

- Embedding the Go binary increases the macOS app size by ~15–20 MB.
- `gomobile bind` adds a build step that must be kept in sync when the Go server changes.
- Local network mode requires both devices to be on the same subnet — it will not work across VPNs that block multicast.
- The `HermitAPIClient` migration removes `GitHubAPIClient` as the primary client, requiring updates across all views that currently call `appState.makeAPIClient()`.

# Alternatives

## Alternative 1: Keep Direct GitHub API in Native App and Fix Alignment Manually

Patch `GitHubAPIClient` to match the Go backend's endpoint choices and inject hermit-anchor metadata in Swift. Rejected: creates ongoing maintenance burden as the backend evolves. Any future server-side enhancement would need to be duplicated in Swift.

## Alternative 2: iPad Connects to Mac via iCloud Relay

Use CloudKit or iCloud Drive as a relay so the iPad can reach a Mac server without being on the same network. Rejected for v1: significant complexity, latency, and CloudKit entitlement requirements. Could be a future enhancement.

## Alternative 3: Compile Go to WASM and Run In-Process on iPad

Use TinyGo or standard Go's WASM target to run server logic in a WKWebView on iPad. Rejected: no TCP socket needed but Go→WASM→Swift bridging is immature and Apple's WKWebView WASM support is constrained.

# Adoption Strategy

1. **Phase 1 (macOS):** Embed Go server, register Bonjour, add Server settings tab, switch `makeAPIClient()` to point at localhost. `GitHubAPIClient` remains as fallback.
2. **Phase 2 (iPad):** Add `NWBrowser` discovery, server selection UI, `HermitAPIClient` consuming Hermit REST API.
3. **Phase 3 (Remote):** Add remote URL configuration and health-check validation. Documented setup guide for self-hosting.

# Unresolved Questions

- Should the embedded server port be fixed (e.g. `8765`) or dynamically assigned? Dynamic avoids port conflicts but requires the Bonjour TXT record to carry the port for discovery.
- Should the Mac advertise itself only when the app is in the foreground, or persistently as a background service (using a Launch Agent)?
- What is the upgrade path when the Go server API version changes and an iPad is still running an older client? Version negotiation via the Bonjour TXT record `version` field is sketched above but not fully designed.
- Should paired tokens survive Mac app restarts (persisted to Keychain)? **Yes — resolved. Tokens are persisted to the Mac Keychain and loaded at launch. Pairing is one-time.**

# Future Possibilities

- Multipeer Connectivity is already used for pairing; it could serve as a full transport fallback when WiFi is unavailable (works over Bluetooth and Apple Wireless Direct Link).
- Remote mode with SSO: replace PAT with an OAuth flow so the hosted server holds the GitHub credentials and devices authenticate with Hermit accounts instead.
- Live collaboration: multiple iPads connected to the same server instance see real-time comment updates via Server-Sent Events or WebSocket.