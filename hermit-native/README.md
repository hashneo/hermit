# hermit-native

Native Swift multiplatform app for Hermit RFC collaboration.

- **macOS 15.2+** — `NSStatusItem` menu bar app with RFC browsing and AI-assisted authoring
- **iPadOS 18.2+** — Full-screen reading and inline commenting app

## Architecture

All data is sourced directly from the GitHub API using a PAT stored in the system Keychain.
No Hermit Go backend is required. See `docs-cms/rfcs/rfc-006-native-swift-app-vision-and-architecture.md`.

## Directory layout

```
Hermit/
├── HermitApp.swift     # @main entry point; platform-conditional scenes
├── Models/                   # AppState and domain types
├── Auth/                     # KeychainHelper
├── Views/                    # SwiftUI views (platform-adaptive)
├── Clients/                  # GitHub API client (hermit-iud, hermit-ru2, …)
├── AI/                       # AIProvider protocol + OpenAI/Apple implementations
├── Voice/                    # VoiceEngine, SpeechRecognizer, SpeechSynthesizer
├── Sessions/                 # RFCInterviewSession, VoiceCommentSession, PublishingSession
├── WebView/                  # WKWebView wrapper + JSBridge
└── Resources/                # Bundled assets (mermaid.min.js, hermit-reader.css)
```

## Open in Xcode

```
open hermit-native/Hermit.xcodeproj
```

Select the **Hermit** scheme and choose a macOS or iPad simulator destination.

## Pending work

See Beads issues blocked by `hermit-n8q` for the full implementation backlog.
