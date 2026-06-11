import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import PDFKit

// MARK: - hermit-ec7: RFC window toolbar — export/print/share + lifecycle transitions

// MARK: - Permission helpers

/// Returns true when the permission level grants approve / mark-implemented rights.
/// Source of truth: GitHub collaborator role — owners and maintainers qualify.
func isPrivilegedPermission(_ permission: String) -> Bool {
    permission == "admin" || permission == "maintain"
}

// MARK: - RFCLifecycleToolbar

/// Toolbar items injected into the RFC detail window navigation bar.
///
/// Layout (left → right):
///   [Export ▾]  |  [Approve] [Mark Implemented]  |  [Share]
///
/// Lifecycle buttons are only shown for main-branch RFCs and are disabled /
/// hidden based on current status and the caller's permission level.
struct RFCLifecycleToolbar: ToolbarContent {
    let rfc: RFC
    /// For PR RFCs: the direct blob URL to the RFC file on the PR branch.
    /// When non-empty, used by "Open RFC File" instead of the PR landing page URL.
    var fileURL: String = ""
    /// Permission level fetched asynchronously by RFCDetailView after load.
    var callerPermission: String = "none"
    var onMarkImplemented: (() async -> Void)? = nil
    /// For PR RFCs: approves the PR and marks the RFC as accepted, then merges.
    var onApproveAndMerge: (() async -> AcceptRFCResult)? = nil
    /// hermit-cns: true when all review threads on the PR are resolved.
    var allThreadsResolved: Bool = false
    /// hermit-cns: true when the PR already has an approval review.
    var prApproved: Bool = false
    /// True when CI checks on the PR head commit are passing.
    var isCIPassing: Bool = false
    /// True when the PR RFC frontmatter already says status: accepted but the PR is not yet merged.
    var prAlreadyAccepted: Bool = false
    /// Merge PR: squash-merges without any frontmatter rewrite (used after CI unblocks or when already accepted).
    var onMergePR: (() async -> MergePRResult)? = nil
    /// Poll CI checks for the given commit SHA. Returns true when CI passed.
    var onPollCI: ((String) async -> Bool)? = nil
    /// True when the PR branch is behind the base branch.
    var isBehind: Bool = false
    /// Called when the user taps "Update Branch".
    var onUpdateBranch: (() async -> Void)? = nil
    /// Number of outstanding REQUEST_CHANGES reviews. Gates Accept & Merge.
    var pendingReviewCount: Int = 0
    /// Called when the user taps the Reviews button — caller presents the reviews sheet.
    var onOpenReviews: (() -> Void)? = nil
    /// Login of the PR author — used to hide Approve & Merge for the author's own PRs.
    var prAuthorLogin: String = ""
    /// Login of the authenticated user.
    var currentUserLogin: String = ""
    /// True while the parent view is loading content — disables all action buttons.
    var isContentLoading: Bool = false
    /// Populated once markdown loads, used for export/print.
    var markdownSource: String = ""

    @State private var isActioning = false
    @State private var pendingAction: LifecycleAction? = nil
    /// Non-nil when the accept commit was made but merge is blocked pending CI.
    @State private var awaitingMergeSHA: String? = nil
    /// True once CI passed (manual path) — enables the Merge button.
    @State private var ciPassed = false
    /// True after ironhide labels were applied — show confirmation badge.
    @State private var handedToIronhide = false

    // MARK: - Lifecycle action model

    /// Represents a lifecycle state change awaiting user confirmation.
    enum LifecycleAction: Identifiable {
        case markImplemented
        case approveAndMerge
        case mergePR
        case updateBranch

        var id: String {
            switch self {
            case .markImplemented:  return "markImplemented"
            case .approveAndMerge:  return "approveAndMerge"
            case .mergePR:          return "mergePR"
            case .updateBranch:     return "updateBranch"
            }
        }

        var title: String {
            switch self {
            case .markImplemented:  return "Mark as Implemented"
            case .approveAndMerge:  return "Approve & Merge"
            case .mergePR:          return "Merge Pull Request"
            case .updateBranch:     return "Update Branch"
            }
        }

        var message: String {
            switch self {
            case .markImplemented:
                return "Marking this RFC as Implemented indicates the described work is complete. " +
                       "This is a terminal state and cannot be undone without admin intervention."
            case .approveAndMerge:
                return "This will approve the pull request and mark the RFC as Accepted, then attempt to squash-merge it. " +
                       "If CI checks are still running, a Merge button will appear once they pass."
            case .mergePR:
                return "CI checks have passed. This will squash-merge the pull request."
            case .updateBranch:
                return "This will merge the latest changes from the base branch into this PR branch. " +
                       "A merge commit will be created on your behalf."
            }
        }

        var confirmLabel: String {
            switch self {
            case .markImplemented:  return "Mark Implemented"
            case .approveAndMerge:  return "Approve & Merge"
            case .mergePR:          return "Merge"
            case .updateBranch:     return "Update Branch"
            }
        }
    }

    // MARK: - Derived state

    private var isMainBranch: Bool {
        if case .mainBranch = rfc.source { return true }
        return false
    }

    private var isPullRequest: Bool {
        if case .pullRequest = rfc.source { return true }
        return false
    }

    private var status: String { rfc.lifecycleStatus ?? "unknown" }

    private var canMarkImplemented: Bool {
        isMainBranch && status == "accepted" && isPrivilegedPermission(callerPermission)
    }

    private var isOwnPR: Bool {
        !prAuthorLogin.isEmpty && !currentUserLogin.isEmpty && prAuthorLogin == currentUserLogin
    }

    /// Approve & Merge is available when: privileged, threads resolved, no pending reviews,
    /// not already approved, and Merge isn't already independently unlocked.
    private var canApproveAndMerge: Bool {
        isPullRequest && isPrivilegedPermission(callerPermission)
        && allThreadsResolved && pendingReviewCount == 0
        && !prApproved && awaitingMergeSHA == nil && !canMergePR
    }

    /// Merge is available once the PR is approved and CI is passing.
    private var canMergePR: Bool {
        isPullRequest && prApproved && isCIPassing && awaitingMergeSHA == nil
    }

    /// Terminal states — no transitions permitted from any role.
    private var isTerminal: Bool {
        ["implemented", "superseded", "rejected"].contains(status)
    }

    // MARK: - Toolbar body

    var body: some ToolbarContent {
        // Export / Print group — macOS only (NSSavePanel / NSPrintOperation)
#if os(macOS)
        ToolbarItem(placement: .automatic) {
            Menu {
                // hermit-1mg / hermit-fdq: must dispatch via Task { @MainActor in }
                // so that NSSavePanel.runModal() / NSPrintOperation.runModal(for:)
                // are called after the current SwiftUI event has fully unwound.
                // Calling @MainActor functions directly from a synchronous Button
                // closure does not guarantee the run-loop is in the right state
                // for modal presentation on macOS.
                Button("Export as PDF…")  { Task { @MainActor in exportPDF()  } }
                Button("Export as RTF…")  { Task { @MainActor in exportRTF()  } }
                Divider()
                Button("Print…") { Task { @MainActor in printRFC() } }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export or print this RFC")
        }
#endif // os(macOS)

        // Lifecycle transition buttons
        ToolbarItemGroup(placement: .automatic) {
            // Main-branch RFCs: accepted → implemented only (approve goes through PR flow)
            if isMainBranch && !isTerminal && status == "accepted" {
                Button {
                    pendingAction = .markImplemented
                } label: {
                    if isActioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Mark Implemented", systemImage: "checkmark.circle.fill")
                    }
                }
                .disabled(!canMarkImplemented || isActioning || isContentLoading)
                .help(canMarkImplemented
                      ? "Mark this RFC as Implemented"
                      : "Requires admin or maintain permission on this repository")
            }

            // PR RFCs — Accept & Merge / Merge / CI waiting / Ironhide / Approve PR / Update Branch
            if isPullRequest {
                if handedToIronhide {
                    Button {} label: {
                        Label("Handed to Ironhide", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                    .disabled(true)
                    .help("Ironhide labels applied. Ironhide will review and merge this PR automatically.")
                } else {
                    // Approve & Merge — hidden once Merge is unlocked or we're awaiting post-accept CI
                    if awaitingMergeSHA == nil && !canMergePR && !prAlreadyAccepted {
                        Button {
                            pendingAction = .approveAndMerge
                        } label: {
                            if isActioning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Approve & Merge", systemImage: "checkmark.seal.fill")
                            }
                        }
                        .disabled(!canApproveAndMerge || isActioning || isContentLoading)
                        .help(pendingReviewCount > 0
                              ? "\(pendingReviewCount) outstanding request-changes review\(pendingReviewCount == 1 ? "" : "s") must be dismissed first"
                              : !allThreadsResolved
                                  ? "Resolve all review comments before approving"
                                  : prApproved
                                      ? "PR is already approved — use Merge once CI passes"
                                      : !isPrivilegedPermission(callerPermission)
                                          ? "Requires admin or maintain permission"
                                          : "Approve the PR and mark this RFC as Accepted")
                    }

                    // Merge — always visible for PR RFCs; enabled when approved + CI passing,
                    // or after Accept & Merge triggered CI polling and it passed,
                    // or when RFC is already marked accepted.
                    if let sha = awaitingMergeSHA {
                        // Post-accept CI polling state
                        if ciPassed {
                            Button {
                                pendingAction = .mergePR
                            } label: {
                                if isActioning {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Merge", systemImage: "arrow.triangle.merge")
                                        .foregroundStyle(.green)
                                }
                            }
                            .disabled(isActioning || isContentLoading)
                            .help("CI checks passed — merge the pull request")
                        } else {
                            Button {} label: {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Waiting for CI…")
                                }
                            }
                            .disabled(true)
                            .help("CI checks are running. Hermit will enable the Merge button when they pass.")
                            .task(id: sha) {
                                let passed = await onPollCI?(sha) ?? false
                                if passed {
                                    ciPassed = true
                                } else {
                                    awaitingMergeSHA = nil
                                }
                            }
                        }
                    } else {
                        Button {
                            pendingAction = .mergePR
                        } label: {
                            if isActioning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Merge", systemImage: "arrow.triangle.merge")
                                    .foregroundStyle(canMergePR || prAlreadyAccepted ? .green : .secondary)
                            }
                        }
                        .disabled(!canMergePR && !prAlreadyAccepted || isActioning || isContentLoading)
                        .help(canMergePR || prAlreadyAccepted
                              ? "RFC is approved — merge the pull request"
                              : !prApproved
                                  ? "PR must be approved before merging"
                                  : "Waiting for CI checks to pass")
                    }
                }

                // Reviews — opens the review sheet for both authors and reviewers.
                Button {
                    onOpenReviews?()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Label("Reviews", systemImage: "exclamationmark.bubble")
                        if pendingReviewCount > 0 {
                            Text("\(pendingReviewCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .foregroundStyle(pendingReviewCount > 0 ? .red : .primary)
                .disabled(isContentLoading)
                .help(pendingReviewCount > 0
                      ? "\(pendingReviewCount) outstanding request-changes review\(pendingReviewCount == 1 ? "" : "s") — merge is blocked"
                      : "View reviews or add a comment")

                // Update Branch — only shown when PR is behind base
                if isBehind {
                    Button {
                        pendingAction = .updateBranch
                    } label: {
                        if isActioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Update Branch", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        }
                    }
                    .disabled(isActioning || isContentLoading)
                    .help("This branch is out-of-date with the base branch. Tap to merge the latest changes in.")
                }
            }
        }

        // Confirmation dialog anchor
        ToolbarItem(placement: .automatic) {
            Text("")
                .frame(width: 0, height: 0)
                .hidden()
                .confirmationDialog(
                    pendingAction?.title ?? "",
                    isPresented: Binding(
                        get: { pendingAction != nil },
                        set: { if !$0 { pendingAction = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let action = pendingAction {
                        Button(action.confirmLabel, role: .destructive) {
                            let captured = action
                            pendingAction = nil
                            Task {
                                switch captured {
                                case .markImplemented: await runAction(onMarkImplemented)
                                case .approveAndMerge:
                                    isActioning = true
                                    if let result = await onApproveAndMerge?() {
                                        if result.handedToIronhide {
                                            handedToIronhide = true
                                        } else if result.blockedByCI {
                                            awaitingMergeSHA = result.commitSHA
                                            ciPassed = false
                                        }
                                    }
                                    isActioning = false
                                case .mergePR:
                                    isActioning = true
                                    if let result = await onMergePR?() {
                                        if result.blockedByCI {
                                            // CI still blocking — keep waiting state, reset ciPassed
                                            ciPassed = false
                                        }
                                        // result.merged == true: caller handles reload
                                    }
                                    isActioning = false
                                case .updateBranch:    await runAction(onUpdateBranch)
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            pendingAction = nil
                        }
                    }
                } message: {
                    if let action = pendingAction {
                        Text(action.message)
                    }
                }
        }

        // Open in Browser — shows PR + file entries for PR RFCs, single entry for main-branch
        ToolbarItem(placement: .automatic) {
            Menu {
                if !fileURL.isEmpty {
                    Button {
                        openURL(rfc.htmlURL)
                    } label: {
                        Label("Open Pull Request", systemImage: "arrow.up.right.square")
                    }
                    Button {
                        openURL(fileURL)
                    } label: {
                        Label("Open RFC File", systemImage: "doc.text")
                    }
                } else {
                    Button {
                        openURL(rfc.htmlURL)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .disabled(fileURL.isEmpty && rfc.htmlURL.isEmpty)
            .help("Open this RFC or its pull request in your browser")
        }

        // Share button
        ToolbarItem(placement: .automatic) {
            ShareLink(item: rfcShareURL()) {
                Label("Share", systemImage: "person.crop.circle.badge.plus")
            }
            .help("Share a link to this RFC")
        }
    }

    // MARK: - Private helpers

    private func openURL(_ string: String) {
        guard !string.isEmpty, let url = URL(string: string) else { return }
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        UIApplication.shared.open(url)
#endif
    }

    private func runAction(_ action: (() async -> Void)?) async {
        guard let action else { return }
        isActioning = true
        await action()
        isActioning = false
    }

    // hermit-1mg: NSSavePanel presented as a window sheet so it attaches to
    // the RFC window.  directoryURL defaults to ~/Downloads so users find
    // their exports without hunting through the filesystem.

    // hermit-ixk: share the real GitHub/Gitea web URL so recipients can open
    // the file in a browser without needing Hermit installed.
    // rfc.htmlURL is populated by the server's CatalogItem.html_url field.
    // Fall back to a hermit:// deep-link only when htmlURL is empty (e.g. for
    // RFCs fetched by an older server build that predates this field).
    private func rfcShareURL() -> URL {
        if !rfc.htmlURL.isEmpty, let webURL = URL(string: rfc.htmlURL) {
            return webURL
        }
        // Fallback: hermit:// deep-link (opens in Hermit on devices that have it).
        let path = rfc.path.isEmpty ? rfc.id : rfc.path
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "hermit://rfcs/\(encoded)") ?? URL(string: "hermit://rfcs")!
    }

#if os(macOS)
    @MainActor
    private func exportPDF() {
        guard let data = renderToPDF() else { return }
        savePanel(filename: pdfFilename(), contentType: .pdf, data: data)
    }

    @MainActor
    private func exportRTF() {
        guard let data = renderToRTF() else { return }
        savePanel(filename: rtfFilename(), contentType: .rtf, data: data)
    }

    @MainActor
    private func savePanel(filename: String, contentType: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = filename
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let dest = panel.url else { return }
                try? data.write(to: dest)
            }
        } else {
            // Fallback: no key window — run modally
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            try? data.write(to: dest)
        }
    }

    /// Build a single NSAttributedString from all parsed blocks and export as RTF.
    private func renderToRTF() -> Data? {
        guard !markdownSource.isEmpty else { return nil }
        let blocks = MarkdownParser.parse(markdownSource)
        guard !blocks.isEmpty else { return nil }

        let doc = NSMutableAttributedString()
        let newline = NSAttributedString(string: "\n")

        for (i, block) in blocks.enumerated() {
            if i > 0 { doc.append(newline) }
            doc.append(attributedString(for: block))
            doc.append(newline)
        }

        return try? doc.data(
            from: NSRange(location: 0, length: doc.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Convert a single MarkdownBlock to an NSAttributedString suitable for RTF export.
    private func attributedString(for block: MarkdownBlock) -> NSAttributedString {
        let bodyFont   = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let monoFont   = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1,
                                                     weight: .regular)

        switch block {

        case .heading(let level, let inlines, _, _):
            let sizes: [Int: CGFloat] = [1: 28, 2: 22, 3: 18, 4: 16]
            let sz = sizes[level] ?? 14
            let wt: NSFont.Weight = level <= 2 ? .semibold : .medium
            let font = NSFont.systemFont(ofSize: sz, weight: wt)
            let str = NSMutableAttributedString(attributedString: inlines.nsAttributedString(font: font))
            if level == 1 || level == 2 {
                // Underline heading 1/2 to mimic the divider in the viewer
                str.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: NSRange(location: 0, length: str.length))
            }
            return str

        case .paragraph(let inlines, _, _):
            return inlines.nsAttributedString(font: bodyFont)

        case .codeBlock(_, let code, _, _):
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = 12
            para.headIndent = 12
            return NSAttributedString(string: code, attributes: [
                .font: monoFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
                .backgroundColor: NSColor(red: 0.92, green: 0.98, blue: 0.92, alpha: 1)
            ])

        case .mermaidBlock(let source, _, _):
            // Mermaid diagrams can't be rendered to RTF — include the source as a code block
            return NSAttributedString(string: source, attributes: [
                .font: monoFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ])

        case .bulletList(let items, _, _):
            return listAttributedString(items: items, ordered: false)

        case .orderedList(let items, _, _):
            return listAttributedString(items: items, ordered: true)

        case .blockquote(let inlines, _, _):
            let attr = inlines.nsAttributedString(font: bodyFont)
            let str = NSMutableAttributedString(attributedString: attr)
            str.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .obliqueness: 0.15
            ], range: NSRange(location: 0, length: str.length))
            return str

        case .horizontalRule(_):
            return NSAttributedString(string: "────────────────────────────────────────",
                                      attributes: [
                                          .font: bodyFont,
                                          .foregroundColor: NSColor.separatorColor
                                      ])

        case .table(let headers, let rows, _, _):
            return tableAttributedString(headers: headers, rows: rows)
        }
    }

    private func listAttributedString(items: [MarkdownBlock.ListItem], ordered: Bool) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let indent: CGFloat = 20
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0
        para.headIndent = indent
        para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

        let result = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            let marker = ordered ? "\(i + 1).\t" : "•\t"
            result.append(NSAttributedString(string: marker, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ]))
            let body = NSMutableAttributedString(attributedString: item.inlines.nsAttributedString(font: bodyFont))
            body.addAttribute(.paragraphStyle, value: para,
                              range: NSRange(location: 0, length: body.length))
            result.append(body)
        }
        return result
    }

    private func tableAttributedString(headers: [[MarkdownInline]],
                                       rows: [[[MarkdownInline]]]) -> NSAttributedString {
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont   = NSFont.systemFont(ofSize: 13, weight: .regular)
        let sep = "  |  "
        let result = NSMutableAttributedString()

        // Header row
        for (i, cell) in headers.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: sep, attributes: [.font: headerFont])) }
            result.append(cell.nsAttributedString(font: headerFont))
        }
        result.append(NSAttributedString(string: "\n"))

        // Divider
        let divider = String(repeating: "─", count: 40)
        result.append(NSAttributedString(string: divider + "\n", attributes: [
            .font: bodyFont, .foregroundColor: NSColor.separatorColor
        ]))

        // Data rows
        for row in rows {
            for (i, cell) in row.enumerated() {
                if i > 0 { result.append(NSAttributedString(string: sep, attributes: [.font: bodyFont])) }
                result.append(cell.nsAttributedString(font: bodyFont))
            }
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    // MARK: - Print / PDF using NSHostingView + PDFKit
    //
    // Strategy: render the RFC into a single tall NSHostingView (no ScrollView,
    // so fittingSize is accurate), then slice it into US Letter pages using
    // CGContext PDF drawing.  Print reuses the same PDF bytes via a PDFDocument
    // so both paths share one render.

    /// US Letter page dimensions in points.
    private static let pageWidth:  CGFloat = 612   // 8.5 in
    private static let pageHeight: CGFloat = 792   // 11 in
    private static let pageMargin: CGFloat = 54    // 0.75 in
    private static let printableWidth: CGFloat = pageWidth - 2 * pageMargin   // 504 pt

    /// Render the RFC to PDF data.  Returns nil if markdownSource is empty or
    /// the view produces zero content height.
    @MainActor
    private func renderToPDF() -> Data? {
        guard !markdownSource.isEmpty else { return nil }
        let blocks = MarkdownParser.parse(markdownSource)
        guard !blocks.isEmpty else { return nil }

        // 1. Build a tall off-screen NSHostingView with no ScrollView so that
        //    fittingSize returns the true content height.
        let content = PrintableRFCView(blocks: blocks, width: Self.printableWidth)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0,
                            width: Self.printableWidth,
                            height: 100_000)
        host.layout()
        let contentHeight = max(host.fittingSize.height, 1)
        host.frame = NSRect(x: 0, y: 0,
                            width: Self.printableWidth,
                            height: contentHeight)
        host.layout()

        // 2. Slice the content into pages and draw via CGContext PDF.
        //
        // Coordinate notes:
        //   • CGContext PDF uses a bottom-left origin (Quartz).
        //   • NSView / AppKit uses a bottom-left origin too, BUT NSHostingView
        //     with a flipped coordinate system (isFlipped = true on NSHostingView)
        //     places its content starting at the TOP of the view frame.
        //   • For each page we need to show rows [yOffset … yOffset+printableHeight]
        //     of the hosting view, placed inside the page margin box.
        //
        // Transform applied each page (all in Quartz bottom-left space):
        //   1. Translate to the margin origin (pageMargin, pageMargin).
        //   2. Flip the Y axis around the centre of the printable area so that
        //      AppKit's top-down content renders right-way-up on the page.
        //   3. Translate upward by the page's yOffset so the correct slice of
        //      the tall view lands in the printable area.
        //
        // Clipping is applied BEFORE the transform in view-local coordinates:
        //   clip to (0, yOffset, printableWidth, printableHeight).

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }

        let pageRect = CGRect(x: 0, y: 0,
                              width: Self.pageWidth,
                              height: Self.pageHeight)
        var mediaBox = pageRect
        guard let ctx = CGContext(consumer: consumer,
                                  mediaBox: &mediaBox,
                                  nil) else { return nil }

        let printableHeight = Self.pageHeight - 2 * Self.pageMargin
        let pageCount = Int(ceil(contentHeight / printableHeight))

        for page in 0 ..< max(pageCount, 1) {
            ctx.beginPDFPage(nil)

            let yOffset = CGFloat(page) * printableHeight

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

            // Step 1 & 2: place origin at top-left of the printable margin box.
            // In Quartz the bottom of the printable area is pageMargin from the
            // bottom of the page, so the top is (pageMargin + printableHeight).
            let transform = NSAffineTransform()
            transform.translateX(by: Self.pageMargin,
                                  yBy: Self.pageMargin + printableHeight)
            // Flip Y so AppKit's top-down content is right-way-up.
            transform.scaleX(by: 1, yBy: -1)
            // Step 3: scroll to the correct vertical slice of the tall view.
            transform.translateX(by: 0, yBy: -yOffset)
            transform.concat()

            // Clip to exactly one page's worth of content in view-local coords.
            NSBezierPath.clip(NSRect(x: 0,
                                     y: yOffset,
                                     width: Self.printableWidth,
                                     height: printableHeight))

            host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)

            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return pdfData as Data
    }

    /// Generate PDF then send it to the system print dialog.
    /// This avoids a second render pass and guarantees print output matches export.
    @MainActor
    private func printRFC() {
        guard let data = renderToPDF() else { return }

        // Write to a temp file so PDFDocument can load it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(pdfFilename())
        do {
            try data.write(to: tmp)
        } catch {
            return
        }

        guard let pdfDoc = PDFDocument(url: tmp) else { return }
        let pdfView = PDFView()
        pdfView.document = pdfDoc
        pdfView.autoScales = true
        // Give the view a sensible frame so AppKit has something to print.
        pdfView.frame = NSRect(x: 0, y: 0,
                               width: Self.pageWidth,
                               height: Self.pageHeight)

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.topMargin    = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin   = 0
        printInfo.rightMargin  = 0
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination   = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered   = false

        let op = NSPrintOperation(view: pdfView, printInfo: printInfo)
        op.showsPrintPanel    = true
        op.showsProgressPanel = true
        if let window = NSApp.keyWindow {
            op.runModal(for: window, delegate: nil,
                        didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    private func pdfFilename() -> String {
        let base = URL(fileURLWithPath: rfc.path)
            .deletingPathExtension().lastPathComponent
        return base.isEmpty ? "rfc.pdf" : "\(base).pdf"
    }

    private func rtfFilename() -> String {
        let base = URL(fileURLWithPath: rfc.path)
            .deletingPathExtension().lastPathComponent
        return base.isEmpty ? "rfc.rtf" : "\(base).rtf"
    }
#endif // os(macOS)
}

// MARK: - PrintableRFCView

#if os(macOS)
/// A gutter-free, comment-free SwiftUI view that renders a parsed RFC for
/// printing or PDF export.  Uses the same `MarkdownBlockView` blocks as
/// `GutterMarkdownView` but omits the 28pt gutter column and all comment UI.
///
/// No ScrollView wrapper — this view must expand to its full content height
/// so that NSHostingView.fittingSize returns an accurate value for PDF slicing.
private struct PrintableRFCView: View {
    let blocks: [MarkdownBlock]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
    }
}
#endif // os(macOS)
