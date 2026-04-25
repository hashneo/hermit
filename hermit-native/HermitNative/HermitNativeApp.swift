import SwiftUI
import AppKit

// MARK: - hermit-y9x: Wire EmbeddedServerManager at app launch (macOS)

@main
struct HermitNativeApp: App {
    @NSApplicationDelegateAdaptor(HermitAppDelegate.self) var appDelegate
    // Use a plain ObservedObject wrapping a shared instance so AppState
    // is created at init time (before SwiftUI scenes render), making it
    // available to the app delegate for server startup.
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
#if os(macOS)
        MenuBarExtra("Hermit", systemImage: "doc.text.magnifyingglass") {
            MenuBarContentView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
#else
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        .onChange(of: appState.serverMode) { _, _ in
            KeychainHelper.shared.serverMode    = appState.serverMode
            KeychainHelper.shared.serverBaseURL = appState.serverBaseURL
        }
#endif
    }
}

// MARK: - App Delegate (macOS)

#if os(macOS)
final class HermitAppDelegate: NSObject, NSApplicationDelegate {
    private var serverStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.startServerIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedServerManager.shared.stop()
    }

    private func startServerIfNeeded() {
        guard !serverStarted else { return }
        serverStarted = true
        DispatchQueue.main.async {
            Task { @MainActor in
                HermitNativeApp.startEmbeddedServer(appState: AppState.shared)
            }
        }
    }
}

extension HermitNativeApp {
    @MainActor
    static func startEmbeddedServer(appState: AppState) {
        guard appState.serverMode == .embeddedLocal else { return }
        EmbeddedServerManager.shared.start(appState: appState)
        if let port = EmbeddedServerManager.shared.port {
            KeychainHelper.shared.serverBaseURL = "http://127.0.0.1:\(port)"
        }
        PairedTokenStore.shared.load()
    }
}

// MARK: - RFC Viewer Window

@MainActor
final class RFCViewerWindowManager {
    static let shared = RFCViewerWindowManager()
    private var controllers: [String: NSWindowController] = [:]

    func open(rfc: RFC, appState: AppState) {
        if let existing = controllers[rfc.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let commentStore = CommentStore()
        let detail = RFCDetailView(rfc: rfc, commentStore: commentStore)
            .environmentObject(appState)
            .environmentObject(commentStore)
            .frame(minWidth: 760, minHeight: 540)

        let hostingController = NSHostingController(rootView: detail)
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = rfc.title
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: screenSize.width * 0.50, height: screenSize.height * 0.90))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controllers[rfc.id] = controller

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.controllers.removeValue(forKey: rfc.id)
            }
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
