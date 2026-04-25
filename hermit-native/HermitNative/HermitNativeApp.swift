import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - hermit-y9x: Wire EmbeddedServerManager at app launch (macOS)

@main
struct HermitNativeApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(HermitAppDelegate.self) var appDelegate
    @ObservedObject private var advertiser = PairingAdvertiser.shared
#endif
    @ObservedObject private var appState = AppState.shared
#if os(iOS)
    @StateObject private var pairingBrowser = PairingBrowser()
#endif

    init() {
#if os(macOS)
        // Start server and advertiser at launch — don't wait for delegate.
        Task { @MainActor in
            HermitNativeApp.startEmbeddedServer(appState: AppState.shared)
        }
#endif
    }

    var body: some Scene {
#if os(macOS)
        MenuBarExtra("Hermit", systemImage: advertiser.pendingInvitation != nil ? "person.crop.circle.badge.exclamationmark" : "doc.text.magnifyingglass") {
            MenuBarContentView()
                .environmentObject(appState)
                .task {
                    // Start server then advertise. Runs once when the menu bar item is created.
                    await MainActor.run {
                        HermitNativeApp.startEmbeddedServer(appState: appState)
                    }
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
                .environmentObject(pairingBrowser)
                .task { pairingBrowser.start() }
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
        let msg = "[\(Date())] [AppDelegate] applicationDidFinishLaunching\n"
        if let d = msg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/hermit-native-debug.log") { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        DispatchQueue.main.async {
            self.startServerIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedServerManager.shared.stop()
        PairingAdvertiser.shared.stop()
    }

    private func startServerIfNeeded() {
        guard !serverStarted else { return }
        serverStarted = true
        Task { @MainActor in
            HermitNativeApp.startEmbeddedServer(appState: AppState.shared)
        }
    }
}

extension HermitNativeApp {
    @MainActor
    static func startEmbeddedServer(appState: AppState) {
        let msg = "[\(Date())] [startEmbeddedServer] serverMode=\(appState.serverMode) serverBaseURL=\(appState.serverBaseURL)\n"
        if let d = msg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/hermit-native-debug.log") { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        guard appState.serverMode == .embeddedLocal else {
            let m = "[\(Date())] [startEmbeddedServer] skipped — not embeddedLocal\n"
            if let d = m.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/hermit-native-debug.log") { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
            return
        }
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
