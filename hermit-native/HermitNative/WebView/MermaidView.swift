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
            image = await MermaidRenderQueue.shared.render(source: source)
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

// MARK: - Serial render queue
//
// Multiple MermaidViews on the same page each call render() concurrently.
// The old shared singleton cancelled the previous render whenever a new one
// arrived, leaving all but the last diagram as "unavailable".
//
// This actor serialises renders: each diagram waits its turn, then gets its
// own dedicated WKWebView instance that is never shared with another render.

actor MermaidRenderQueue {
    static let shared = MermaidRenderQueue()

    func render(source: String) async -> PlatformImage? {
        // Each call gets its own renderer — no shared state, no cancellation.
        let renderer = await MermaidRenderer()
        return await renderer.render(source: source)
    }
}

@MainActor
final class MermaidRenderer: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<PlatformImage?, Never>?
    private var pollTask: Task<Void, Never>?

    func render(source: String) async -> PlatformImage? {
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

        // Render at 2x width so the rasterised snapshot has enough pixels to
        // stay sharp when the image is expanded. SwiftUI's .scaledToFit()
        // scales it back down for the inline display.
        let renderWidth: CGFloat = 1800
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: renderWidth, height: 600), configuration: config)
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
                    await self.snapshot(wv: wv)
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Timeout — snapshot whatever is there
            await self.snapshot(wv: wv)
        }
    }

    private func snapshot(wv: WKWebView) async {
        // Resize frame to content height first
        if let h = try? await wv.evaluateJavaScript("document.body.scrollHeight") as? CGFloat, h > 0 {
            wv.frame.size.height = h
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: wv.frame.size)
        // Request snapshot at 2x the logical width so the raster image has
        // enough pixels to remain sharp when the user expands the diagram.
        if #available(macOS 14.0, iOS 17.0, *) {
            config.snapshotWidth = NSNumber(value: Double(wv.frame.size.width) * 2)
        }

        do {
            let img = try await wv.takeSnapshot(configuration: config)
            finish(image: img)
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
    body { background: white; }
    .mermaid { width: 100%; }
    .mermaid svg { width: 100% !important; height: auto !important; display: block; }
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
