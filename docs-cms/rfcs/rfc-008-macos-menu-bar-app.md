---
title: macOS Menu Bar App
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [macos, menu-bar, rfc, statusitem, swift, swiftui]
id: rfc-008
project_id: hermit
doc_uuid: a1b2c3d4-0003-4000-8000-100000000008
---

# Summary

This RFC defines the design and behaviour of the Hermit macOS menu bar app — a persistent `NSStatusItem` popover that gives engineers instant access to the RFC catalog, document reading, and AI-assisted RFC creation without leaving their current context. The menu bar app is read-only for RFC review; full commenting is available on iPadOS (rfc-009).

# Motivation

Engineers spend most of their working day at a Mac. The friction of opening a browser, navigating to the Hermit web UI, and finding a specific RFC is high enough that many engineers defer reviews or skip them entirely. A menu bar app eliminates that friction: one keyboard shortcut surfaces the full RFC catalog and a rendered document view in under a second, from anywhere on the desktop.

The secondary motivation is RFC creation. Engineers often have an idea for an RFC while deep in other work. A voice-first, hands-free RFC authoring flow accessible from the menu bar lets them capture that idea immediately, before context switches bury it.

# Detailed Design

## NSStatusItem Popover

The app registers an `NSStatusItem` in the macOS menu bar on launch. The status item uses a custom icon (the Hermit glyph). On click, it presents an `NSPopover` anchored to the status bar item.

```swift
// HermitApp.swift (macOS conditional)
@main struct HermitApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { SettingsView() } }
    #else
    var body: some Scene { WindowGroup { iPadRootView() } }
    #endif
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(named: "HermitMenuBarIcon")
        statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 520, height: 680)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover())
    }
}
```

### Popover Dimensions

- Default: **520 × 680 pts**
- Minimum: **400 × 500 pts** (user-resizable)
- The popover can be "detached" (pinned) to a floating window via a pin button in the toolbar, giving engineers a persistent side panel while working.

### Keyboard Shortcut

A global keyboard shortcut shows/hides the popover from any app. Default: **⌘⇧H**. Configurable in Settings. Implemented via `NSEvent.addGlobalMonitorForEvents`.

## Popover Layout

```text
┌────────────────────────────────────────┐
│ ⬡ Hermit               [↗] [⚙] [📌] │  ← toolbar
│────────────────────────────────────────│
│ hashicorp / hermit                  ▾  │  ← repo picker
│────────────────────────────────────────│
│  RFC List                              │
│  ─────────────────────────────────     │
│  ◉ rfc-001  High-Level Architecture    │
│    Draft · Main branch                 │
│  ─────────────────────────────────     │
│  ◉ rfc-005  Label-Driven PR Discovery  │
│    Draft · PR #12              🔴 New  │
│  ─────────────────────────────────     │
│  ◉ rfc-006  Native Swift App           │
│    Draft · PR #67              🔴 New  │
│                                        │
│  [+ New RFC]                           │
└────────────────────────────────────────┘
```

When an RFC is selected, the popover expands horizontally (or the content area switches) to show the document:

```text
┌──────────────────┬─────────────────────────────────────┐
│  RFC List        │  rfc-006 Native Swift App            │
│  ─────────────── │  ─────────────────────────────────── │
│  ◉ rfc-001  ...  │  [rendered WKWebView]                │
│  ◉ rfc-005  ...  │                                      │
│ ▶ rfc-006  ...   │  # Summary                           │
│  ◉ rfc-007  ...  │  This RFC defines the vision...      │
│                  │                                      │
│  [+ New RFC]     │  [↗ Open in browser]                 │
└──────────────────┴─────────────────────────────────────┘
```

## Toolbar Actions

| Button | Action |
|---|---|
| ↗ (open external) | Opens current RFC on GitHub in default browser |
| ⚙ (settings) | Opens Settings window (separate `NSWindow`) |
| 📌 (pin) | Detaches popover into a floating `NSPanel` |

## RFC List

The RFC list shows items from two sources:

1. **Main branch RFCs** — files matching `rfc-NNN-*.md` in the configured `docs_path` on the default branch.
2. **PR-backed RFCs** — open, non-draft PRs with the `hermit:rfc-ready` label that include an RFC file in their diff.

Each list item displays:
- RFC title (from frontmatter or first H1)
- Lifecycle status badge: `Draft` / `Accepted` / `Implemented`
- Source label: `Main branch` or `PR #N`
- "New" badge: shown for PR-backed RFCs discovered since the last time the popover was opened (persisted to `UserDefaults`)

List is sorted: PR-backed RFCs first (newest PR number first), then main branch RFCs (alphabetical).

Refresh: the list auto-refreshes when the popover is opened. A pull-down gesture on the list triggers a manual refresh.

## RFC Document View

Tapping an RFC in the list loads the document in the right panel:

1. `GitHubAPIClient.fetchRFCContent()` fetches raw markdown.
2. A Swift-side markdown-to-HTML conversion pass is applied (headings get anchor IDs, fenced code blocks get language class attributes, Mermaid fences are wrapped in `<div class="mermaid">`).
3. The HTML is injected into a `WKWebView` with:
   - `hermit-reader.css` — typography, brand colours, dark mode via `prefers-color-scheme`
   - `mermaid.min.js` — bundled (not CDN) for offline use; auto-initialises on load
4. The WKWebView is read-only on macOS — no text selection handler or comment flow.

Loading state: a skeleton shimmer is shown while the API call is in flight. Error state: an inline error banner with a "Retry" button.

## New RFC Button

The `[+ New RFC]` button at the bottom of the list opens the RFC interview flow (rfc-010) inside the popover. The user can choose text or voice mode. On macOS, the popover expands to accommodate the interview UI or the interview opens in a dedicated `NSPanel`.

## Background Polling and Badge

The app polls GitHub for new PR-backed RFCs every **15 minutes** while the app is running (using a `Task` with a `clock.sleep` loop). The polling interval is configurable in Settings (5 / 15 / 30 / 60 minutes, or Off).

When new PR-backed RFCs are found (not seen before):
- The `NSStatusItem` button shows a badge dot (custom drawn on the icon via `NSImage` compositing).
- A macOS `UNUserNotification` banner is sent: *"New RFC ready for review: {title}"*.

The set of "seen" RFC IDs is persisted to `UserDefaults` and cleared when the list is opened.

## Settings Window

A standard macOS `Settings` scene with three tabs:

### Account
- GitHub PAT field (write-only display, shows last 4 chars)
- Repository owner + name
- Docs path (default: `docs-cms/rfcs/`)
- "Validate" button → calls `GET /repos/{owner}/{repo}` to confirm access

### AI
- Provider picker: Apple Intelligence / OpenAI / None
- If OpenAI: API key field + model selector (gpt-4o / gpt-4o-mini)
- System prompt editor for RFC interview (advanced, collapsible)

### Notifications
- Background polling interval
- Notification banner toggle

## App Lifecycle

The app runs as an `LSUIElement` (menu bar only, no Dock icon, no main window). This is set in `Info.plist`:

```xml
<key>LSUIElement</key>
<true/>
```

On first launch, if no PAT is configured, the Settings window opens automatically. The popover cannot be used until a valid PAT is stored.

# Drawbacks

- `LSUIElement` apps are less discoverable — engineers must know the keyboard shortcut or click the menu bar icon. There is no Dock presence.
- The popover has limited vertical space. Long RFCs require scrolling inside the WKWebView. The pin/detach feature mitigates this by allowing the window to be resized freely.
- Background polling consumes memory and network even when the engineer is not actively using Hermit. The configurable polling interval and an "Off" option address this.

# Alternatives

## Alternative 1: Full macOS Window App (Dock-based)

A standard `NSWindowController` app with a Dock icon and full-size window. More screen real estate but higher cognitive overhead — you have to switch apps to use it. Rejected in favour of the ambient menu bar model.

## Alternative 2: Safari Extension

A browser extension that injects the Hermit UI into GitHub PR pages. Provides context but requires the engineer to be on the GitHub page in the first place. No voice or AI capabilities. Rejected.

# Adoption Strategy

The macOS app is distributed as a `.app` bundle built from the `hermit-native/` Xcode project. Engineers install it by copying to `/Applications`. No package manager or MDM integration is required at this stage.

# Unresolved Questions

- Should the detached floating panel persist its position across relaunches? Likely yes, using `NSWindow.setFrameAutosaveName`.
- How should the app handle multiple GitHub accounts or repositories? The current design supports one configured repo at a time. A repository switcher in the popover toolbar is planned but not specified here.
- Should the macOS app support commenting (currently excluded)? If PR review turnaround data shows that engineers want to leave quick comments from the menu bar without switching to iPad, this should be revisited.

# Future Possibilities

- Spotlight-like search across all RFC titles and content, accessible from the keyboard shortcut without opening the full popover.
- macOS Shortcuts integration: "Create RFC", "List open RFCs" as Shortcuts actions.
- Touch Bar support (legacy).
- Notification Centre widget showing the count of RFCs awaiting review.