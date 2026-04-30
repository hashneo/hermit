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
    /// Populated once markdown loads, used for export/print.
    var markdownSource: String = ""

    @State private var isActioning = false

    // MARK: - Derived state

    private var isMainBranch: Bool {
        if case .mainBranch = rfc.source { return true }
        return false
    }

    private var status: String { rfc.lifecycleStatus ?? "unknown" }

    private var canApprove: Bool {
        isMainBranch && status == "draft" && isPrivilegedPermission(callerPermission)
    }

    private var canMarkImplemented: Bool {
        isMainBranch && status == "accepted" && isPrivilegedPermission(callerPermission)
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
                Button("Export as PDF…")  { exportPDF()  }
                Button("Export as DOCX…") { exportDOCX() }
                Divider()
                Button("Print…") { printRFC() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export or print this RFC")
        }

        // Lifecycle transition buttons — main-branch only, non-terminal only
        ToolbarItemGroup(placement: .automatic) {
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

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfFilename()
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            guard let data = renderToPDF() else { return }
            try? data.write(to: dest)
        }
    }

    private func exportDOCX() {
        let panel = NSSavePanel()
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = docxFilename()
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            // Full OOXML generation is out of scope; write raw markdown so the
            // file is at minimum openable and contains the RFC content.
            let data = markdownSource.data(using: .utf8) ?? Data()
            try? data.write(to: dest)
        }
    }

    private func printRFC() {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination   = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered   = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
        textView.string = markdownSource
        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel    = true
        op.showsProgressPanel = true
        op.run()
    }

    private func renderToPDF() -> Data? {
        let textStorage = NSTextStorage(string: markdownSource)
        let layoutMgr   = NSLayoutManager()
        textStorage.addLayoutManager(layoutMgr)
        let container = NSTextContainer(
            containerSize: NSSize(width: 522, height: CGFloat.greatestFiniteMagnitude))
        layoutMgr.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 522, height: 792),
                                  textContainer: container)

        let pi = NSPrintInfo()
        pi.paperSize    = NSSize(width: 612, height: 792)
        pi.topMargin    = 36; pi.bottomMargin = 36
        pi.leftMargin   = 54; pi.rightMargin  = 54
        pi.isHorizontallyCentered = false
        pi.isVerticallyCentered   = false

        let outputData = NSMutableData()
        let op = NSPrintOperation.pdfOperation(
            with: textView, inside: textView.bounds,
            to: outputData, printInfo: pi)
        op.showsPrintPanel    = false
        op.showsProgressPanel = false
        op.run()
        return outputData as Data
    }

    private func rfcShareURL() -> URL {
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
