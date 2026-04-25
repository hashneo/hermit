import SwiftUI

// MARK: - hermit-zcd: RFCPreviewView — WKWebView draft preview with raw markdown edit toggle
// hermit-maw: PublishingView — step-by-step progress UI with success/error states

struct RFCPreviewView: View {
    @State var markdown: String
    var onPublish: (() -> Void)? = nil

    @State private var showRaw = false
    @State private var showPublishing = false
    @Environment(\.dismiss) private var dismiss

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
                            mermaidScript: BundledAssets.mermaidScript
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
                PublishingView(markdown: markdown, onDone: {
                    showPublishing = false
                    onPublish?()
                    dismiss()
                })
            }
        }
    }
}

// MARK: - hermit-maw: PublishingView

struct PublishingView: View {
    let markdown: String
    var onDone: (() -> Void)? = nil

    // In real wiring, session is injected; here we use a local instance for compilability.
    @State private var currentStep: PublishingSession.Step = .idle
    @State private var progress: Double = 0
    @State private var errorMessage: String? = nil
    @State private var publishedPR: RFCPullRequest? = nil

    var body: some View {
        VStack(spacing: 24) {
            if let pr = publishedPR {
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
            } else if let error = errorMessage {
                // Error
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.red)
                    Text("Publishing Failed").font(.title2).bold()
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Dismiss") { onDone?() }.buttonStyle(.bordered)
            } else {
                // In-progress
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(currentStep.rawValue)
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(PublishingSession.Step.allCases.prefix(4).enumerated()), id: \.offset) { idx, step in
                        HStack {
                            let done = step.rawValue <= currentStep.rawValue
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
    }
}
