import SwiftUI

// MARK: - hermit-zcd: RFCPreviewView — WKWebView draft preview with raw markdown edit toggle
// hermit-maw: PublishingView — step-by-step progress UI with success/error states
// hermit-zbp: client/docsPath/rfcLabel injected as params, passed through to PublishingView
// hermit-kiz: PublishingView wired to PublishingSession

struct RFCPreviewView: View {
    @State var markdown: String
    // hermit-zbp: client context injected from RFCInterviewView (via environment + explicit params)
    let client: any HermitClientProtocol
    let docsPath: String
    let rfcLabel: String
    var onPublish: (() -> Void)? = nil

    @State private var showRaw = false
    @State private var showPublishing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Group {
                if showRaw {
                    TextEditor(text: $markdown)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                } else {
                    WebViewRenderer(
                        html: MarkdownRenderer.htmlString(
                            from: markdown,
                            css: BundledAssets.readerCSS,
                            mermaidScript: BundledAssets.mermaidScript,
                            prefersDarkMode: colorScheme == .dark
                        )
                    )
                }
            }
            .navigationTitle("RFC Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $showRaw) {
                        Label("Raw", systemImage: "doc.plaintext")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish as PR") { showPublishing = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $showPublishing) {
                // hermit-zbp + hermit-kiz: pass client context through to PublishingView
                PublishingView(
                    markdown: markdown,
                    client: client,
                    docsPath: docsPath,
                    rfcLabel: rfcLabel,
                    onDone: {
                        showPublishing = false
                        onPublish?()
                        dismiss()
                    }
                )
            }
        }
    }
}

// MARK: - hermit-maw / hermit-kiz: PublishingView — wired to PublishingSession

struct PublishingView: View {
    let markdown: String
    // hermit-kiz: injected client context (was missing before)
    let client: any HermitClientProtocol
    let docsPath: String
    let rfcLabel: String
    var onDone: (() -> Void)? = nil

    // hermit-kiz: @StateObject replaces the four orphaned @State vars
    @StateObject private var session: PublishingSessionBox

    init(
        markdown: String,
        client: any HermitClientProtocol,
        docsPath: String,
        rfcLabel: String,
        onDone: (() -> Void)? = nil
    ) {
        self.markdown  = markdown
        self.client    = client
        self.docsPath  = docsPath
        self.rfcLabel  = rfcLabel
        self.onDone    = onDone
        _session = StateObject(wrappedValue:
            PublishingSessionBox(client: client, docsPath: docsPath, rfcLabel: rfcLabel))
    }

    var body: some View {
        VStack(spacing: 24) {
            if let pr = session.inner.publishedPR {
                // Success
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.green)
                    Text("RFC Published!").font(.title2).bold()
                    Text("PR #\(pr.number): \(pr.title)")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Link("View on GitHub →", destination: URL(string: pr.htmlURL)!)
                }
                Button("Done") { onDone?() }
                    .buttonStyle(.borderedProminent)

            } else if let error = session.inner.errorMessage {
                // Error
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.red)
                    Text("Publishing Failed").font(.title2).bold()
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Dismiss") { onDone?() }.buttonStyle(.bordered)

            } else {
                // In-progress — driven by session.inner.currentStep / progress
                VStack(spacing: 16) {
                    ProgressView(value: session.inner.progress)
                        .progressViewStyle(.linear)
                    Text(session.inner.currentStep.rawValue)
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(PublishingSession.Step.allCases.prefix(4).enumerated()),
                            id: \.offset) { idx, step in
                        HStack {
                            let done = step.rawValue <= session.inner.currentStep.rawValue
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? .green : .secondary)
                            Text(step.rawValue).foregroundStyle(done ? .primary : .secondary)
                            Spacer()
                        }
                    }
                }
                .padding()
            }
        }
        .padding(32)
        .presentationDetents([.medium])
        // hermit-kiz: kick off publish on appear, pulling authorLogin from fetchCurrentUser
        .task {
            guard session.inner.currentStep == .idle else { return }
            let rfcTitle = extractTitle(from: markdown)
            let authorLogin: String
            do {
                authorLogin = try await client.fetchCurrentUser()
            } catch {
                authorLogin = "unknown"
            }
            await session.inner.publish(
                markdown: markdown,
                rfcTitle: rfcTitle,
                authorLogin: authorLogin
            )
        }
    }

    // hermit-kiz: extract `title:` from YAML frontmatter, fallback to first H1
    private func extractTitle(from md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        // frontmatter title: field
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                return String(trimmed.dropFirst(6))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        // first H1
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "Untitled RFC"
    }
}

// MARK: - PublishingSessionBox
// @MainActor ObservableObject wrapper so PublishingView can hold PublishingSession as @StateObject.
// PublishingSession itself is @MainActor final class ObservableObject — we just need
// a stable init-time box since StateObject requires the wrappedValue to be created once.

@MainActor
final class PublishingSessionBox: ObservableObject {
    let inner: PublishingSession
    init(client: any HermitClientProtocol, docsPath: String, rfcLabel: String) {
        inner = PublishingSession(client: client, docsPath: docsPath, rfcLabel: rfcLabel)
    }
}
