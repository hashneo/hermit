import SwiftUI
import WebKit

// MARK: - MermaidView: renders a mermaid diagram to a native image via offscreen WKWebView snapshot

struct MermaidView: View {
    let source: String
    @State private var image: PlatformImage? = nil
    @State private var failed = false
    @State private var showPopout = false   // iOS/iPadOS sheet

    var body: some View {
        Group {
            if let img = image {
                ZStack(alignment: .bottomTrailing) {
#if os(macOS)
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
#else
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
#endif
                    // Expand button
                    Button {
#if os(macOS)
                        DiagramWindowManager.shared.open(image: img, title: "Diagram")
#else
                        showPopout = true
#endif
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Open diagram in viewer")
                }
#if !os(macOS)
                .sheet(isPresented: $showPopout) {
                    NavigationStack {
                        DiagramPopoutView(image: img) {
                            showPopout = false
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showPopout = false }
                            }
                        }
                    }
                }
#endif
            } else if failed {
                Text("Diagram unavailable")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Rendering diagram…").foregroundStyle(.secondary).font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: source) {
            image = await MermaidRenderer.shared.render(source: source)
            failed = image == nil
        }
    }
}

// MARK: - Offscreen renderer

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<PlatformImage?, Never>?
    private var pollTask: Task<Void, Never>?

    func render(source: String) async -> PlatformImage? {
        // Cancel any in-flight render
        pollTask?.cancel()
        continuation?.resume(returning: nil)
        continuation = nil

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.startRender(source: source)
        }
    }

    private func startRender(source: String) {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        wv.navigationDelegate = self
#if os(macOS)
        wv.setValue(false, forKey: "drawsBackground")
#else
        wv.isOpaque = false
        wv.backgroundColor = .clear
#endif
        self.webView = wv
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
    }

    // Called by navigation delegate after page load — poll until mermaid SVG is ready
    fileprivate func pageLoaded() {
        guard let wv = webView else { return }
        pollTask = Task { @MainActor in
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if let ready = try? await wv.evaluateJavaScript("document.querySelector('.mermaid svg') !== null") as? Bool, ready {
                    await snapshot(wv: wv)
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Timeout — snapshot whatever is there
            await snapshot(wv: wv)
        }
    }

    private func snapshot(wv: WKWebView) async {
        // Resize frame to content height first
        if let h = try? await wv.evaluateJavaScript("document.body.scrollHeight") as? CGFloat, h > 0 {
            wv.frame.size.height = h
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: wv.frame.size)

        do {
            let img = try await wv.takeSnapshot(configuration: config)
#if os(macOS)
            finish(image: img)
#else
            finish(image: img)
#endif
        } catch {
            finish(image: nil)
        }
    }

    private func finish(image: PlatformImage?) {
        pollTask?.cancel()
        pollTask = nil
        webView = nil
        continuation?.resume(returning: image)
        continuation = nil
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.pageLoaded() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(image: nil) }
    }
}

// MARK: - HTML

private func mermaidHTML(source: String) -> String {
    let encoded: String
    if let data = try? JSONSerialization.data(withJSONObject: [source], options: []),
       let s = String(data: data, encoding: .utf8),
       s.hasPrefix("["), s.hasSuffix("]") {
        encoded = String(s.dropFirst().dropLast())
    } else {
        let esc = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        encoded = "\"\(esc)\""
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: white; display: flex; justify-content: center; padding: 16px; }
    .mermaid svg { max-width: 100%; height: auto; display: block; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    </head>
    <body>
    <div class="mermaid" id="diagram"></div>
    <script>
    mermaid.initialize({ startOnLoad: false, theme: 'default' });
    document.getElementById('diagram').textContent = \(encoded);
    mermaid.run({ nodes: [document.getElementById('diagram')] });
    </script>
    </body>
    </html>
    """
}
