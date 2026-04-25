import SwiftUI
import AppKit

// MARK: - hermit-y9x: Wire EmbeddedServerManager at app launch (macOS)

@main
struct HermitNativeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
#if os(macOS)
        MenuBarExtra("Hermit", systemImage: "doc.text.magnifyingglass") {
            MenuBarContentView()
                .environmentObject(appState)
                .task {
                    // Start the embedded Go server once the content view (and
                    // therefore @StateObject appState) is fully initialised.
                    HermitNativeApp.startEmbeddedServer(appState: appState)
                }
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
            // iPad: when server mode changes persist to Keychain
            KeychainHelper.shared.serverMode    = appState.serverMode
            KeychainHelper.shared.serverBaseURL = appState.serverBaseURL
        }
#endif
    }

#if os(macOS)
    // Called automatically by the SwiftUI lifecycle via the `init` below.
    init() {
        // Server startup is driven by the .task modifier on the Settings scene below,
        // which has access to the real @StateObject appState instance.
    }
#endif
}

// MARK: - macOS app lifecycle helper

#if os(macOS)
/// AppDelegate shim that starts and stops the embedded server at the correct
/// application lifecycle points. Registered via `@NSApplicationDelegateAdaptor`
/// when the app target sets a delegate — or called directly from scene init.
///
/// Because `@main` uses the SwiftUI App protocol we use a scene-level `.task`
/// modifier in the Settings scene to drive server startup instead of a full
/// AppDelegate, keeping the architecture simple.
extension HermitNativeApp {
    /// Scene-level task body that starts the embedded server once AppState is ready.
    @MainActor
    static func startEmbeddedServer(appState: AppState) {
        // Only start the embedded server when the user has selected embedded mode.
        // Remote mode means a user-supplied serverBaseURL is already in Keychain.
        guard appState.serverMode == .embeddedLocal else { return }

        EmbeddedServerManager.shared.start(appState: appState)

        // start() sets appState.serverBaseURL directly after the Go server binds.
        // Persist it to Keychain so subsequent launches skip setup.
        if let port = EmbeddedServerManager.shared.port {
            let url = "http://127.0.0.1:\(port)"
            KeychainHelper.shared.serverBaseURL = url
        }

        // Load paired token map into memory so Go middleware can validate requests.
        PairedTokenStore.shared.load()
    }
}

// MARK: - RFC Viewer Window

/// Opens (or focuses) a standalone NSWindow showing the full RFC detail view.
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
