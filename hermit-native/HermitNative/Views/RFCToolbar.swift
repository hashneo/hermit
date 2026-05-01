import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    /// Permission level fetched asynchronously by RFCDetailView after load.
    var callerPermission: String = "none"
    var onApprove: (() async -> Void)?        = nil
    var onMarkImplemented: (() async -> Void)? = nil
    /// hermit-cns: for PR RFCs, called when the Approve PR button is tapped.
    var onApprovePR: (() async -> Void)? = nil
    /// hermit-cns: true when all review threads on the PR are resolved.
    var allThreadsResolved: Bool = false
    /// hermit-cns: true when the PR already has an approval review.
    var prApproved: Bool = false
    /// Populated once markdown loads, used for export/print.
    var markdownSource: String = ""

    @State private var isActioning = false

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

    private var canApprove: Bool {
        isMainBranch && status == "draft" && isPrivilegedPermission(callerPermission)
    }

    private var canMarkImplemented: Bool {
        isMainBranch && status == "accepted" && isPrivilegedPermission(callerPermission)
    }

    /// hermit-cns: Approve PR is available when the caller has admin/maintain,
    /// all review threads are resolved, and the PR has not already been approved.
    private var canApprovePR: Bool {
        isPullRequest && isPrivilegedPermission(callerPermission) &&
        allThreadsResolved && !prApproved
    }

    /// Terminal states — no transitions permitted from any role.
    private var isTerminal: Bool {
        ["implemented", "superseded", "rejected"].contains(status)
    }

    // MARK: - Toolbar body

    var body: some ToolbarContent {
        // Export / Print group
        ToolbarItem(placement: .automatic) {
            Menu {
                // hermit-1mg / hermit-fdq: must dispatch via Task { @MainActor in }
                // so that NSSavePanel.runModal() / NSPrintOperation.runModal(for:)
                // are called after the current SwiftUI event has fully unwound.
                // Calling @MainActor functions directly from a synchronous Button
                // closure does not guarantee the run-loop is in the right state
                // for modal presentation on macOS.
                Button("Export as PDF…")  { Task { @MainActor in exportPDF()  } }
                Button("Export as DOCX…") { Task { @MainActor in exportDOCX() } }
                Divider()
                Button("Print…") { Task { @MainActor in printRFC() } }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export or print this RFC")
        }

        // Lifecycle transition buttons
        ToolbarItemGroup(placement: .automatic) {
            // Main-branch RFCs: draft → accepted → implemented
            if isMainBranch && !isTerminal {
                if status == "draft" {
                    Button {
                        Task { await runAction(onApprove) }
                    } label: {
                        if isActioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Approve", systemImage: "checkmark.seal")
                        }
                    }
                    .disabled(!canApprove || isActioning)
                    .help(canApprove
                          ? "Approve this RFC (moves status to Accepted)"
                          : "Requires admin or maintain permission on this repository")
                }

                if status == "accepted" {
                    Button {
                        Task { await runAction(onMarkImplemented) }
                    } label: {
                        if isActioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Mark Implemented", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .disabled(!canMarkImplemented || isActioning)
                    .help(canMarkImplemented
                          ? "Mark this RFC as Implemented"
                          : "Requires admin or maintain permission on this repository")
                }
            }

            // hermit-cns: PR RFCs — Approve PR button.
            // Shown when: caller has admin/maintain, all threads are resolved,
            // and the PR has not already been approved.
            if isPullRequest {
                Button {
                    Task { await runAction(onApprovePR) }
                } label: {
                    if isActioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Approve PR", systemImage: "checkmark.seal.fill")
                    }
                }
                .disabled(!canApprovePR || isActioning)
                .help(
                    prApproved
                        ? "You have already approved this PR"
                        : !allThreadsResolved
                            ? "Resolve all review comments before approving"
                            : !isPrivilegedPermission(callerPermission)
                                ? "Requires admin or maintain permission"
                                : "Approve and mark this RFC PR ready to merge"
                )
            }
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

    private func runAction(_ action: (() async -> Void)?) async {
        guard let action else { return }
        isActioning = true
        await action()
        isActioning = false
    }

    // hermit-1mg: NSSavePanel must run modally on the main thread with an
    // explicit window context.  Using runModal() is the safest approach when
    // the calling site may not have a key-window available.

    @MainActor
    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfFilename()
        let response = panel.runModal()
        guard response == .OK, let dest = panel.url else { return }
        guard let data = renderToPDF() else { return }
        try? data.write(to: dest)
    }

    @MainActor
    private func exportDOCX() {
        let panel = NSSavePanel()
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = docxFilename()
        let response = panel.runModal()
        guard response == .OK, let dest = panel.url else { return }
        // Full OOXML generation is out of scope; write raw markdown so the
        // file is at minimum openable and contains the RFC content.
        let data = markdownSource.data(using: .utf8) ?? Data()
        try? data.write(to: dest)
    }

    // MARK: - Print / PDF using NSHostingView
    //
    // Previous approach used a detached NSTextView holding raw markdownSource text —
    // this produced unformatted plain-text output.  The correct approach is to render
    // the same MarkdownBlockView blocks used by GutterMarkdownView into an NSHostingView
    // (no gutter, no comment UI), lay it out at US Letter width, then hand that view
    // to NSPrintOperation / dataWithPDF(inside:).

    /// US Letter printable width in points (72 pt/in × 8.5in − 2×54pt margins).
    private static let printWidth: CGFloat = 504

    /// Build the off-screen host view containing the rendered RFC content.
    @MainActor
    private func makeHostingView(width: CGFloat = printWidth) -> NSView? {
        guard !markdownSource.isEmpty else { return nil }
        let blocks = MarkdownParser.parse(markdownSource)
        guard !blocks.isEmpty else { return nil }

        let content = PrintableRFCView(blocks: blocks, width: width)
        let host = NSHostingView(rootView: content)
        // Size the host view to fit its ideal content at the given width.
        let fittingSize = host.fittingSize
        let height = max(fittingSize.height, 1)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Force AppKit layout so the frame is accurate before PDF capture.
        host.layout()
        return host
    }

    @MainActor
    private func printRFC() {
        guard let view = makeHostingView() else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.topMargin    = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin   = 54
        printInfo.rightMargin  = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination   = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered   = false

        let op = NSPrintOperation(view: view, printInfo: printInfo)
        op.showsPrintPanel    = true
        op.showsProgressPanel = true
        if let window = NSApp.keyWindow {
            op.runModal(for: window, delegate: nil,
                        didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    @MainActor
    private func renderToPDF() -> Data? {
        guard let view = makeHostingView() else { return nil }
        return view.dataWithPDF(inside: view.bounds)
    }

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

    private func pdfFilename() -> String {
        let base = URL(fileURLWithPath: rfc.path)
            .deletingPathExtension().lastPathComponent
        return base.isEmpty ? "rfc.pdf" : "\(base).pdf"
    }

    private func docxFilename() -> String {
        let base = URL(fileURLWithPath: rfc.path)
            .deletingPathExtension().lastPathComponent
        return base.isEmpty ? "rfc.docx" : "\(base).docx"
    }
}

// MARK: - PrintableRFCView

/// A gutter-free, comment-free SwiftUI view that renders a parsed RFC for
/// printing or PDF export.  Uses the same `MarkdownBlockView` blocks as
/// `GutterMarkdownView` but omits the 28pt gutter column and all comment UI.
private struct PrintableRFCView: View {
    let blocks: [MarkdownBlock]
    let width: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
        }
    }
}
