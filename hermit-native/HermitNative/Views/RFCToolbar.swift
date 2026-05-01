import SwiftUI
import AppKit
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
    @State private var pendingAction: LifecycleAction? = nil

    // MARK: - Lifecycle action model

    /// Represents a lifecycle state change awaiting user confirmation.
    enum LifecycleAction: Identifiable {
        case approve
        case markImplemented
        case approvePR

        var id: String {
            switch self {
            case .approve:          return "approve"
            case .markImplemented:  return "markImplemented"
            case .approvePR:        return "approvePR"
            }
        }

        var title: String {
            switch self {
            case .approve:          return "Approve RFC"
            case .markImplemented:  return "Mark as Implemented"
            case .approvePR:        return "Approve Pull Request"
            }
        }

        var message: String {
            switch self {
            case .approve:
                return "Approving this RFC will move it from Draft to Accepted. " +
                       "This signals community consensus and cannot be undone without admin intervention."
            case .markImplemented:
                return "Marking this RFC as Implemented indicates the described work is complete. " +
                       "This is a terminal state and cannot be undone without admin intervention."
            case .approvePR:
                return "Approving this pull request will submit a GitHub approval review on your behalf, " +
                       "marking the RFC PR as ready to merge."
            }
        }

        var confirmLabel: String {
            switch self {
            case .approve:          return "Approve"
            case .markImplemented:  return "Mark Implemented"
            case .approvePR:        return "Approve PR"
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
                Button("Export as RTF…")  { Task { @MainActor in exportRTF()  } }
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
                        pendingAction = .approve
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
                        pendingAction = .markImplemented
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
                    pendingAction = .approvePR
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

        // Confirmation dialog anchor — hidden view that carries the lifecycle
        // confirmation dialog, since .confirmationDialog cannot be applied
        // directly to ToolbarItemGroup on macOS.
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
                                case .approve:         await runAction(onApprove)
                                case .markImplemented: await runAction(onMarkImplemented)
                                case .approvePR:       await runAction(onApprovePR)
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
    private func exportRTF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = rtfFilename()
        let response = panel.runModal()
        guard response == .OK, let dest = panel.url else { return }
        guard let data = renderToRTF() else { return }
        try? data.write(to: dest)
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

    private func listAttributedString(items: [[MarkdownInline]], ordered: Bool) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let indent: CGFloat = 20
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0
        para.headIndent = indent
        para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

        let result = NSMutableAttributedString()
        for (i, inlines) in items.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            let marker = ordered ? "\(i + 1).\t" : "•\t"
            result.append(NSAttributedString(string: marker, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ]))
            let body = NSMutableAttributedString(attributedString: inlines.nsAttributedString(font: bodyFont))
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
                            height: 100_000)   // generous initial height
        host.layout()
        let contentHeight = max(host.fittingSize.height, 1)
        host.frame = NSRect(x: 0, y: 0,
                            width: Self.printableWidth,
                            height: contentHeight)
        host.layout()

        // 2. Slice the content into pages and draw via CGContext PDF.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }

        let pageRect = CGRect(x: 0, y: 0,
                              width: Self.pageWidth,
                              height: Self.pageHeight)
        var mediaBox = pageRect
        guard let ctx = CGContext(consumer: consumer,
                                  mediaBox: &mediaBox,
                                  nil) else { return nil }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)

        let printableHeight = Self.pageHeight - 2 * Self.pageMargin
        let pageCount = Int(ceil(contentHeight / printableHeight))

        for page in 0 ..< max(pageCount, 1) {
            ctx.beginPDFPage(nil)

            // Translate so the current page's slice of the content appears
            // within the margin box, with the coordinate system flipped to
            // match AppKit's top-left origin.
            let yOffset = CGFloat(page) * printableHeight

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            let transform = NSAffineTransform()
            // Move to top-left margin corner
            transform.translateX(by: Self.pageMargin,
                                  yBy: Self.pageMargin)
            // Flip vertically so AppKit draws top-down
            transform.translateX(by: 0,
                                  yBy: printableHeight)
            transform.scaleX(by: 1, yBy: -1)
            // Scroll to the correct vertical slice
            transform.translateX(by: 0, yBy: -yOffset)
            transform.concat()

            // Clip to the printable area so content doesn't bleed between pages
            NSBezierPath.clip(NSRect(x: 0, y: yOffset,
                                     width: Self.printableWidth,
                                     height: printableHeight))

            host.displayIgnoringOpacity(host.bounds, in: nsCtx)

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

    private func rtfFilename() -> String {
        let base = URL(fileURLWithPath: rfc.path)
            .deletingPathExtension().lastPathComponent
        return base.isEmpty ? "rfc.rtf" : "\(base).rtf"
    }
}

// MARK: - PrintableRFCView

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
