---
title: iPadOS Reading and Commenting App
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [commenting, ipad, ipados, reading, rfc, swift, swiftui]
id: rfc-009
project_id: hermit
doc_uuid: a1b2c3d4-0004-4000-8000-100000000009
---

# Summary

This RFC defines the iPadOS surface of the Hermit native app — a full-screen, touch-first interface for reading RFC documents comfortably and leaving inline comments via text or voice. The iPad experience is designed for the "couch" use case: an engineer away from their desk, reading through an RFC in a relaxed posture, and contributing thoughtful review comments without needing a keyboard.

# Motivation

RFC review is currently tethered to a desktop browser. This means review tends to happen during working hours at a desk, often hurried and shallow. Many engineers do their best technical reading in low-distraction environments: at home on the couch, in a café, or on the commute.

A native iPadOS app with a distraction-free reading mode, comfortable typography, and a low-friction voice commenting capability makes RFC review accessible in the moments when engineers actually have time and focus for it.

# Detailed Design

## Layout: NavigationSplitView

The app uses a three-column `NavigationSplitView`:

```text
┌──────────────┬──────────────────────────┬────────────────────┐
│  Sidebar     │  RFC Detail              │  Thread Panel      │
│              │                          │  (trailing, opt.)  │
│  [Repo]   ▾  │  rfc-009 iPad App        │                    │
│              │  ──────────────────────  │  Thread #1         │
│  ◉ rfc-001   │  # Summary               │  "The layout..."   │
│  ◉ rfc-005   │                          │  Line 14–17        │
│  ◉ rfc-006   │  This RFC defines...     │  ── Reply ──       │
│ ▶ rfc-009   │                          │  [Add reply...]    │
│  ◉ rfc-010   │  ## Detailed Design      │                    │
│              │                          │  Thread #2         │
│  [+ New RFC] │  [WKWebView]             │  "Should we..."    │
│              │                          │  Line 42–44        │
└──────────────┴──────────────────────────┴────────────────────┘
```

On compact size classes (Split View, iPhone-size iPad window), the three columns collapse to a standard push-navigation stack.

## Sidebar

The sidebar mirrors the RFC list from rfc-008 (macOS menu bar), sharing `RFCListView.swift`:

- Repository picker at the top
- RFC list items: title, lifecycle badge, source label, commentable indicator
- Filter chips along the top: **All** / **Draft** / **Accepted** / **PR** (commentable only)
- `[+ New RFC]` button at the bottom
- Pull-to-refresh triggers `GitHubAPIClient` to re-fetch the catalog

## RFC Detail View

The detail column renders the selected RFC in a `WKWebView`:

1. Raw markdown is fetched via `GitHubAPIClient.fetchRFCContent()`.
2. Markdown is converted to HTML client-side (headings → anchor IDs, Mermaid fences → `<div class="mermaid">`).
3. HTML is loaded into `WKWebView` with injected `hermit-reader.css` and bundled `mermaid.min.js`.
4. The WKWebView is configured for reading comfort:
   - Max content width: 72ch centred
   - Font: system serif (New York) for body, system monospace for code
   - Line height: 1.7
   - Dark mode: automatic via `prefers-color-scheme`

### Text Selection → Comment Trigger

For PR-backed RFCs (where `commentable == true`), a JavaScript event listener fires on `selectionchange`. When the selection is non-empty and the user lifts their finger, the JS bridge fires:

```javascript
// Injected into WKWebView
document.addEventListener('selectionchange', () => {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) return;
    const range = sel.getRangeAt(0);
    const rects = range.getClientRects();
    window.webkit.messageHandlers.textSelection.postMessage({
        text: sel.toString(),
        startOffset: range.startOffset,
        endOffset: range.endOffset,
        // Line numbers derived from anchor elements in the rendered HTML
        anchorId: findNearestAnchor(range.startContainer)
    });
});
```

The Swift `WKScriptMessageHandler` (`JSBridge.swift`) receives this message and:

1. Resolves the line number from the anchor ID (the rendered HTML has `id="L{n}"` span markers injected during the markdown→HTML pass).
2. Shows a floating `+` button near the selected text (positioned via the `rects` data from the JS bridge).
3. Tapping the button opens the `ComposeCommentView` sheet.

### Line Number Injection

During the markdown→HTML conversion, the converter inserts invisible line markers:

```html
<span id="L42" class="hermit-line-marker" data-line="42"></span>
```

These are injected at the start of each paragraph and heading, allowing the JS bridge to map any DOM selection back to a markdown line number for the GitHub PR comment API.

## Comment Compose Sheet

`ComposeCommentView` is presented as a bottom sheet (`presentationDetents: [.medium, .large]`):

```text
┌────────────────────────────────────────────┐
│ Add Comment                          [✕]   │
│ ──────────────────────────────────────────  │
│ > "This RFC defines the vision and top-    │
│   level architecture for a native Swift..."│
│   Lines 14–17                              │
│ ──────────────────────────────────────────  │
│ [TextEditor: type your comment...]         │
│                                            │
│  🎤 Voice    [Cancel]  [Submit Comment]    │
└────────────────────────────────────────────┘
```

- Selected text is shown as a blockquote for context.
- Line range is shown beneath the quote.
- `TextEditor` is the primary input.
- "Voice" button switches to voice comment mode (rfc-011).
- "Submit Comment" calls `GitHubAPIClient.createPRComment()` with:
  - `body`: composed text
  - `commit_id`: head SHA of the PR at the time the RFC was loaded
  - `path`: RFC file path in the repository
  - `line`: resolved markdown line number

### Stale SHA Handling

If the PR has been updated since the user opened the RFC (new commits pushed), the stored `headSHA` is stale and GitHub will reject the comment with a `422`. The app detects this on submission, shows an alert:

> "This PR has been updated since you started reading. Refresh to load the latest version?"

Tapping "Refresh" reloads the RFC content and clears all pending comments. The user's composed text is preserved in memory so they can re-select and re-submit.

## Thread Panel

The trailing panel shows all PR review comments for the current RFC, fetched via `GitHubAPIClient.listPRComments()`.

### Thread Grouping

GitHub PR review comments are grouped into threads using `in_reply_to_id`. The first comment in a thread is the root; subsequent comments with matching `in_reply_to_id` are replies.

```swift
struct CommentThread: Identifiable {
    let id: Int                 // root comment ID
    let rootComment: PRComment
    var replies: [PRComment]
    var isResolved: Bool        // derived from reply bodies containing "✓ Resolved"
    var lineRange: String       // "Lines 14–17"
}
```

### Thread Item Layout

```text
┌────────────────────────────────────┐
│ @stevetaylor · 2h ago              │
│ "The layout section could benefit  │
│  from a more concrete example..."  │
│ Lines 14–17                        │
│                                    │
│   @reviewerB · 1h ago              │
│   "Agreed, I'll add a diagram."    │
│                                    │
│  [Reply...]   [✓ Resolve]          │
└────────────────────────────────────┘
```

"Resolve" posts a `"✓ Resolved"` reply via `GitHubAPIClient.replyToPRComment()` (GitHub REST does not expose thread resolution; this matches the existing Go server behaviour).

The thread panel refreshes automatically every 60 seconds while visible, and on pull-down.

## Thread Gutter Markers

The WKWebView detail view shows thread indicator dots in the document margin at the line numbers of active threads. These are injected as absolutely-positioned HTML elements after the thread list is loaded:

```javascript
// Called from Swift after threads are fetched
function markThreadLines(threads) {
    threads.forEach(t => {
        const marker = document.getElementById('L' + t.startLine);
        if (marker) {
            const dot = document.createElement('span');
            dot.className = 'hermit-thread-dot';
            dot.dataset.threadId = t.id;
            marker.parentNode.insertBefore(dot, marker);
        }
    });
}
```

Tapping a dot scrolls the thread panel to the corresponding thread and highlights it.

## PR Approval

An "Approve PR" button appears in the detail view toolbar for PR-backed RFCs. Tapping it:

1. Shows a confirmation sheet: "Approve PR #N — {title}?"
2. On confirm: calls `GitHubAPIClient.approvePR()` → `POST /repos/{owner}/{repo}/pulls/{prNumber}/reviews { event: "APPROVE" }`.
3. Shows a success toast; the RFC's source label updates to show the approval state.

## Reading Mode

A "Reading Mode" toggle in the toolbar removes the sidebar and thread panel, expanding the RFC to full-screen width. This is the primary couch/relaxed reading posture. A single swipe from the left edge restores the sidebar.

In Reading Mode:
- Thread dots remain visible in the margin.
- Tapping a thread dot slides in the thread panel from the right as an overlay sheet.
- The compose sheet is still accessible via text selection.

## Offline Behaviour

The last successfully loaded RFC content for each item is held in memory for the duration of the app session. If the device loses connectivity:
- The RFC list shows cached items with a "Cached" indicator.
- Previously loaded RFC documents are still readable.
- Comment submission is disabled (greyed out "Submit" button) with an explanatory message.

No persistent disk cache is implemented in this version.

# Drawbacks

- GitHub REST API does not support real thread resolution — the "✓ Resolved" reply convention is a workaround and does not update the GitHub PR UI's thread-resolved count.
- Inline comment creation requires knowing the line number in the diff, which requires the RFC file to be part of a PR diff. Main-branch RFCs cannot be commented on (same constraint as the web UI).
- The stale SHA problem (comments rejected after PR is updated) creates friction. Engineers reading long RFCs who pause for a while may find their comments rejected.

# Alternatives

## Alternative 1: UITextView with AttributedString

Use a native `UITextView` with `AttributedString` rendering instead of `WKWebView`. Eliminates the web view overhead but loses Mermaid, complex table rendering, and syntax-highlighted code blocks. Rejected.

## Alternative 2: Native Comment Threading

Build a custom comment thread UI using GitHub's GraphQL API (which exposes real thread state). Would enable real resolution, but GraphQL in Swift requires a more complex client implementation. Deferred to a future RFC.

# Adoption Strategy

The iPadOS app is the same binary as the macOS app, built from the `hermit-native/` Xcode project with the multiplatform target. Distribution via direct install (`.ipa` sideloading) for internal use initially; App Store distribution is a future consideration.

# Unresolved Questions

- Should the app support Apple Pencil for handwriting-to-text in the comment compose field? `PencilKit` could be layered onto `ComposeCommentView` with minimal additional work.
- Should the thread panel auto-open when the user taps a thread dot in the document, or should it require an explicit tap on the thread panel icon? UX testing needed.
- Should comment drafts persist across app launches (e.g. `@AppStorage` or `UserDefaults`)? Prevents losing partially-written comments when the app is backgrounded.

# Future Possibilities

- Split-screen multitasking: read the RFC in one Split View pane and the related GitHub PR diff in another.
- Apple Pencil annotation: draw directly on the RFC document with annotations stored as GitHub comments.
- SharePlay: collaborative RFC reading session where multiple engineers see the same document with live cursor positions.