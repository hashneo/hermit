import SwiftUI
import WebKit

// MARK: - hermit-kzt: WKWebView SwiftUI wrapper

#if os(macOS)
import AppKit

/// SwiftUI wrapper around WKWebView for RFC reading on macOS.
struct WebViewRenderer: NSViewRepresentable {
    let html: String
    var onTextSelected: ((String) -> Void)? = nil

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(onTextSelected: onTextSelected)
    }

    func makeNSView(context: Context) -> WKWebView {
        let wv = makeWebView(coordinator: context.coordinator)
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(html, baseURL: nil)
    }
}

#else
import UIKit

/// SwiftUI wrapper around WKWebView for RFC reading on iPadOS.
struct WebViewRenderer: UIViewRepresentable {
    let html: String
    var onTextSelected: ((String) -> Void)? = nil

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(onTextSelected: onTextSelected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = makeWebView(coordinator: context.coordinator)
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(html, baseURL: nil)
    }
}
#endif

// MARK: - Shared factory

private func makeWebView(coordinator: WebViewCoordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(coordinator, name: "textSelected")
    let prefs = WKWebpagePreferences()
    prefs.allowsContentJavaScript = true
    config.defaultWebpagePreferences = prefs
    let wv = WKWebView(frame: .zero, configuration: config)
    wv.navigationDelegate = coordinator
#if os(macOS)
    wv.setValue(false, forKey: "drawsBackground")
#else
    wv.isOpaque = false
    wv.backgroundColor = .clear
    wv.scrollView.backgroundColor = .clear
#endif
    return wv
}

// MARK: - hermit-2lv: JSBridge coordinator

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onTextSelected: ((String) -> Void)?

    init(onTextSelected: ((String) -> Void)?) {
        self.onTextSelected = onTextSelected
    }

    // Receive text selection events from JS
    func userContentController(_ ucc: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "textSelected",
              let body = message.body as? [String: Any],
              let text = body["text"] as? String
        else { return }
        DispatchQueue.main.async { self.onTextSelected?(text) }
    }

    // Open external links in the system browser
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
#if os(macOS)
            NSWorkspace.shared.open(url)
#else
            UIApplication.shared.open(url)
#endif
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
