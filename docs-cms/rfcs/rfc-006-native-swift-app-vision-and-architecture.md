---
title: Native Swift App — Vision and Architecture
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [native, swift, macos, ipad, architecture, rfc]
id: rfc-006
project_id: hermit
doc_uuid: a1b2c3d4-0001-4000-8000-100000000006
---

# Summary

This RFC defines the vision and top-level architecture for a native Swift application that brings Hermit RFC collaboration to macOS and iPadOS. The app provides engineers with a fast, always-available menu bar experience on macOS for browsing and authoring RFCs, and a comfortable reading and commenting experience on iPadOS. All data is sourced directly from the GitHub API — there is no Hermit backend server dependency.

# Motivation

The existing Hermit web UI is browser-based and requires a running Go server. This creates friction for two important use cases:

1. **Engineers at their desks** — quickly checking whether new RFCs are ready for review, reading them without context-switching to a browser, and starting new RFCs from a keyboard shortcut.
2. **Engineers away from their desks** — sitting on a couch, reading an RFC on an iPad, and leaving inline comments in a natural touch-first interface.

A native Swift app can serve both use cases from a single codebase while providing capabilities the web UI cannot — persistent background notifications, system-level voice input, on-device AI, and deep OS integration via Keychain and the macOS status bar.

# Detailed Design

## Platform Targets

| Platform | Minimum OS | Primary Surface |
|---|---|---|
| macOS | 15.2+ | `NSStatusItem` menu bar popover |
| iPadOS | 18.2+ | Full-screen `NavigationSplitView` |

A single Xcode multiplatform target produces both apps from one Swift codebase. Platform-conditional views (`#if os(macOS)`) handle divergent surfaces; shared models, clients, sessions, and business logic are fully shared.

## High-Level Architecture

```
hermit-native/
│
├── AI/                         # AI provider abstraction + RFC interview prompts
├── Auth/                       # Keychain storage for PAT and AI keys
├── Clients/                    # GitHub API client (direct, no backend)
├── Sessions/                   # RFC interview state machine, voice comment session
├── Voice/                      # Mic capture, STT, TTS
├── Models.swift                # Codable GitHub + domain types
├── Views/                      # SwiftUI views (platform-adaptive)
└── WebView/                    # WKWebView wrapper + JS bridge
```

## Core Principles

1. **GitHub is the only backend.** All reads (RFC list, file content, PR threads) and writes (comments, PR creation) go directly to the GitHub REST API using a Personal Access Token stored in the system Keychain. There is no Hermit server.

2. **Single multiplatform target.** macOS and iPadOS share all logic. Only views diverge where the platform interaction model requires it.

3. **AI is an optional accelerator.** The app is fully functional without AI configuration. AI-assisted RFC authoring and voice transcription are additive features that degrade gracefully to text-only mode when unavailable.

4. **WKWebView for document rendering.** RFC markdown is fetched as raw content from GitHub and rendered server-side equivalent by converting to HTML with goldmark-compatible rules client-side, then displayed in a `WKWebView`. This preserves Mermaid diagram support via a client-side Mermaid.js rendering pass injected into the web view.

5. **Privacy by default.** When Apple Intelligence is configured, all AI inference runs on-device via the `FoundationModels` framework. No document content is sent to external services unless the user explicitly configures OpenAI as the provider.

## Component Responsibilities

| Component | Responsibility |
|---|---|
| `GitHubAPIClient` | All GitHub REST API calls: RFC file fetching, PR listing, comment CRUD, PR creation |
| `KeychainHelper` | Secure storage of PAT, OpenAI key, server preferences |
| `AIProvider` protocol | Abstraction over Apple Intelligence and OpenAI for chat and transcription |
| `RFCInterviewSession` | Stateful multi-turn conversational interview for RFC authoring |
| `VoiceCommentSession` | Single-turn voice capture + transcription for inline comments |
| `VoiceEngine` | `AVAudioEngine` mic streaming, silence detection, waveform data |
| `SpeechRecognizer` | `SFSpeechRecognizer` (on-device) or Whisper (OpenAI) transcription |
| `SpeechSynthesizer` | `AVSpeechSynthesizer` TTS for AI question readback in voice mode |
| `WebViewRenderer` | `WKWebView` wrapped as `UIViewRepresentable`/`NSViewRepresentable` |
| `JSBridge` | Receives text selection events from JavaScript in the web view |

## Feature Matrix by Platform

| Feature | macOS | iPadOS |
|---|---|---|
| Browse RFC list | ✓ | ✓ |
| Read RFC (rendered) | ✓ | ✓ |
| Mermaid diagrams | ✓ | ✓ |
| Dark mode | ✓ | ✓ |
| Inline commenting | — | ✓ |
| Voice comments | ✓ | ✓ |
| AI RFC creation (text) | ✓ | ✓ |
| AI RFC creation (voice) | ✓ | ✓ |
| PR approval | — | ✓ |
| New RFC badge notification | ✓ | — |
| Background RFC polling | ✓ | — |
| Open in browser | ✓ | ✓ |

## System Frameworks Used

- `WebKit` — WKWebView for RFC rendering
- `AVFoundation` — microphone capture, audio session management, TTS playback
- `Speech` — `SFSpeechRecognizer` for on-device speech-to-text
- `FoundationModels` — Apple Intelligence on-device LLM (macOS 15.2+ / iOS 18.2+)
- `Security` — Keychain Services for PAT and API key storage
- `UserNotifications` — badge and banner for new RFC alerts (macOS)

No third-party Swift packages are required.

## Data Flow: Reading an RFC

```
App launch
  → KeychainHelper loads PAT
  → GitHubAPIClient.listRepositories() [GitHub API: GET /user/repos or configured list]
  → User selects repo
  → GitHubAPIClient.listOpenRFCPullRequests() [GET /repos/{owner}/{repo}/pulls?labels=hermit:rfc-ready]
  → GitHubAPIClient.listMainBranchRFCs() [GET /repos/{owner}/{repo}/contents/{docs_path}]
  → RFC list rendered in sidebar
  → User taps RFC
  → GitHubAPIClient.fetchRFCContent() [GET /repos/{owner}/{repo}/contents/{path}?ref={sha}]
  → Raw markdown decoded
  → Markdown → HTML conversion (client-side, with Mermaid.js injection)
  → WKWebView loads HTML string
```

## Data Flow: Creating an RFC

See rfc-010 (AI-Assisted RFC Authoring) and rfc-012 (RFC Publishing via GitHub API) for full detail.

```
User triggers "New RFC"
  → RFCInterviewSession begins (text or voice mode)
  → Multi-turn AI conversation collects: title, problem, proposal, alternatives, questions
  → AIProvider assembles final markdown from RFC template
  → User previews in WKWebView
  → User taps "Publish as PR"
  → GitHubAPIClient creates branch, commits file, opens PR with hermit:rfc-ready label
  → RFC appears in list immediately
```

# Drawbacks

- Requires macOS 15.2+ and iPadOS 18.2+, excluding older devices.
- Direct GitHub API usage means no caching or projection layer — every list view makes live API calls. Rate limiting (5,000 req/hr for authenticated PAT) is unlikely to be hit in practice but must be handled gracefully.
- Duplicates some GitHub API integration logic that will eventually exist in the Go server. When the server is built, the native app client layer should be refactored to call the Hermit API instead.
- No offline read capability beyond in-session memory cache.

# Alternatives

## Alternative 1: Wait for the Hermit Go Server

Defer the native app until the Go backend exists and the native app can call the Hermit REST API (as originally designed in rfc-003). This avoids duplicated GitHub API integration but delays the native experience by an unknown amount.

**Rejected** — the native use cases (menu bar, iPad reading, voice RFC creation) are valuable independently and the GitHub API surface needed is narrow and stable.

## Alternative 2: macOS Only

Build only the macOS menu bar app and skip iPadOS for now.

**Rejected** — the iPad reading-and-commenting use case was identified as equally important from the start. The shared codebase makes it low-incremental-cost to support both.

## Alternative 3: Electron or React Native

Reuse the existing React UI in a cross-platform wrapper.

**Rejected** — eliminates access to `FoundationModels`, `AVFoundation` voice pipelines, `NSStatusItem`, and system Keychain integration. The native experience is the point.

# Adoption Strategy

The native app lives in `hermit-native/` alongside the existing `ui/` directory. It is a standalone Xcode project and does not affect the Go server or web UI. Engineers opt in by building and installing the app from source. When the Go backend matures, a future RFC will define migration of the `GitHubAPIClient` calls to `HermitClient` calls.

# Unresolved Questions

- RFC file numbering: when creating a new RFC, the app must determine the next available `rfc-NNN` number by scanning the GitHub directory listing. This is straightforward but must handle concurrent PR creation from multiple authors gracefully. See rfc-012.
- Mermaid rendering: client-side Mermaid.js rendering in WKWebView requires bundling the Mermaid JS library or loading it from CDN. CDN is simpler but breaks offline. Bundling adds binary size. Decision deferred to implementation.
- Comment sync: inline comments created from iPadOS via the GitHub API are PR review comments. Resolving them from the iPad requires the GitHub API resolve endpoint. The full comment lifecycle on iPad is detailed in rfc-009.

# Future Possibilities

- When the Hermit Go server is built, replace `GitHubAPIClient` with `HermitClient` and remove direct GitHub API coupling from the native app.
- Notification Center integration for @mention alerts in RFC comments.
- Shortcuts app integration for automating RFC creation workflows.
- Vision Pro — read RFC documents in a spatial computing environment.
