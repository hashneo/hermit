import SwiftUI
import AppKit

@main
struct HermitNativeApp: App {
    @StateObject private var appState = AppState()

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
#endif
    }
}

#if os(macOS)
// MARK: - RFC Viewer Window

/// Opens (or focuses) a standalone NSWindow showing the full RFC detail view.
@MainActor
final class RFCViewerWindowManager {
    static let shared = RFCViewerWindowManager()
    private var controllers: [String: NSWindowController] = [:]

    func open(rfc: RFC, appState: AppState) {
        // Reuse existing window for this RFC if already open
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
        hostingController.sizingOptions = []  // don't let content drive window size
        let window = NSWindow(contentViewController: hostingController)
        window.title = rfc.title
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: screenSize.width * 0.50, height: screenSize.height * 0.90))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controllers[rfc.id] = controller

        // Clean up when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.controllers.removeValue(forKey: rfc.id)
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
