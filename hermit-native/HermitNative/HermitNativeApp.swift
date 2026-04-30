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
        // AccountStore.shared initialises itself — migration from legacy
        // single-account config happens synchronously in its init().
        _ = AccountStore.shared
    }

    var body: some Scene {
#if os(macOS)
        MenuBarExtra("Hermit", systemImage: advertiser.pendingInvitation != nil ? "person.crop.circle.badge.exclamationmark" : "doc.text.magnifyingglass") {
            MenuBarContentView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

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
                // hermit-txn: handle hermit://rfc/<path> deep links on iPadOS
                .onOpenURL { url in
                    if let path = HermitActivity.rfcPath(from: url) {
                        appState.pendingDeepLinkPath = path
                    }
                }
        }
        .onChange(of: appState.serverMode) { _, _ in
            ConfigStore.shared.serverMode    = appState.serverMode
            ConfigStore.shared.serverBaseURL = appState.serverBaseURL
        }
#endif
    }
}

// MARK: - App Delegate (macOS)

#if os(macOS)

final class HermitAppDelegate: NSObject, NSApplicationDelegate {
    private var serverStarted = false
    private var restartObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // hermit-9ds: live-restart the embedded server when credentials/repos change.
        restartObserver = NotificationCenter.default.addObserver(
            forName: .hermitRestartRequired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.serverStarted == true else { return }
            Task { @MainActor in
                RepoRFCCache.shared.invalidateAll()
                EmbeddedServerManager.shared.restart(appState: AppState.shared)
                if let port = EmbeddedServerManager.shared.port {
                    ConfigStore.shared.serverBaseURL = "http://127.0.0.1:\(port)"
                }
            }
        }
        let msg = "[\(Date())] [AppDelegate] applicationDidFinishLaunching\n"
        let _logPath = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-native-debug.log").path
        if let d = msg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: _logPath) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        DispatchQueue.main.async {
            self.startServerIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedServerManager.shared.stop()
        PairingAdvertiser.shared.stop()
    }

    // hermit-z9j: receive Handoff continuation from iPad
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == HermitActivity.handoff,
              let rfcID = userActivity.userInfo?[HermitActivity.keyRFCID] as? String else {
            return false
        }
        let line = userActivity.userInfo?[HermitActivity.keySelectedLine] as? Int
        let appState = AppState.shared
        appState.pendingHandoffRFCID = rfcID
        appState.pendingHandoffLine  = line
        return true
    }

    // hermit-txn: handle hermit://rfc/<path> deep links opened from external apps on macOS
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let path = HermitActivity.rfcPath(from: url) {
                AppState.shared.pendingDeepLinkPath = path
                break
            }
        }
    }

    private func startServerIfNeeded() {
        guard !serverStarted else { return }
        serverStarted = true
        Task { @MainActor in
            let appState = AppState.shared

            // If ConfigStore already has config (e.g. from a previous run or
            // install-keychain-pat.sh), skip detection entirely.
            let hasConfig = BookmarkStore.shared.hasBookmark || ConfigStore.shared.isConfigured
            if !hasConfig {
                // Try silent auto-detection first (reads DevConfig/ bundle or repo layout).
                // Only show the folder picker if that also fails.
                if let detected = try? GiteaAutoConfig.detect() {
                    appState.isAuthenticated = true
                    appState.baseURL         = detected.baseURL
                    appState.giteaBaseURL    = detected.giteaBaseURL
                    appState.repoOwner       = detected.owner
                    appState.repoName        = detected.repo
                    appState.docsPath        = detected.docsPath
                    appState.rfcLabel        = detected.rfcLabel
                    appState.pat             = detected.pat
                    appState.serverMode      = .embeddedLocal
                    // Persist so future launches skip detection
                    ConfigStore.shared.apply(ConfigStore.RepoConfig(
                        baseURL:   detected.giteaBaseURL.isEmpty ? detected.baseURL : detected.giteaBaseURL,
                        owner:     detected.owner,
                        repo:      detected.repo,
                        docsPath:  detected.docsPath,
                        rfcLabel:  detected.rfcLabel
                    ))
                    ConfigStore.shared.serverBaseURL = detected.baseURL
                    if !detected.pat.isEmpty {
                        if let conn = AccountStore.shared.connections.first {
                            AccountStore.shared.update(conn, token: detected.pat)
                        }
                    }
                } else {
                    do {
                        let detected = try GiteaAutoConfig.promptAndDetect()
                        appState.isAuthenticated = true
                        appState.baseURL         = detected.baseURL
                        appState.giteaBaseURL    = detected.giteaBaseURL
                        appState.repoOwner       = detected.owner
                        appState.repoName        = detected.repo
                        appState.docsPath        = detected.docsPath
                        appState.rfcLabel        = detected.rfcLabel
                        appState.pat             = detected.pat
                        appState.serverMode      = .embeddedLocal
                    } catch {
                        // User cancelled or selected wrong folder — server won't start.
                        // They can retry via Settings → Repository → Change…
                        print("[startServerIfNeeded] repo setup cancelled or failed: \(error)")
                        return
                    }
                }
            }
            HermitNativeApp.startEmbeddedServer(appState: appState)
        }
    }
}

extension HermitNativeApp {
    @MainActor
    static func startEmbeddedServer(appState: AppState) {
        let _logPath = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-native-debug.log").path
        let msg = "[\(Date())] [startEmbeddedServer] serverMode=\(appState.serverMode) serverBaseURL=\(appState.serverBaseURL)\n"
        if let d = msg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: _logPath) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        guard appState.serverMode == .embeddedLocal else {
            let m = "[\(Date())] [startEmbeddedServer] skipped — not embeddedLocal\n"
            if let d = m.data(using: .utf8), let fh = FileHandle(forWritingAtPath: _logPath) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
            return
        }
        EmbeddedServerManager.shared.start(appState: appState)
        if let port = EmbeddedServerManager.shared.port {
            ConfigStore.shared.serverBaseURL = "http://127.0.0.1:\(port)"
        }
        PairedTokenStore.shared.load()
    }
}

// MARK: - Settings Window Manager (macOS)
// Opens the Settings window imperatively so it works from the MenuBarExtra
// panel without needing @Environment(\.openSettings).

#if os(macOS)
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var controller: NSWindowController?

    func open() {
        if let existing = controller?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView().environmentObject(AppState.shared)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 860))
        window.center()
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif


@MainActor
final class RFCViewerWindowManager {
    static let shared = RFCViewerWindowManager()
    private var controllers: [String: NSWindowController] = [:]
    // hermit-z9j: one donated activity per open RFC window
    private var activities: [String: NSUserActivity] = [:]

    func open(rfc: RFC, appState: AppState) {
        // hermit-olq: track selection in AppState for NSUserActivity access
        appState.selectedRFC = rfc
        appState.selectedLine = nil

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

        // Record in recents so the menu bar shows recently opened RFCs.
        let repoID = RepositoryStore.shared.repositories.first?.id ?? UUID()
        RecentRFCStore.shared.record(rfc, repoID: repoID)

        // hermit-z9j: donate Handoff activity for this RFC window
        let activity = NSUserActivity(activityType: HermitActivity.handoff)
        activity.title = rfc.title
        activity.isEligibleForHandoff = true
        activity.userInfo = HermitActivity.userInfo(for: rfc, selectedLine: nil)
        activity.becomeCurrent()
        activities[rfc.id] = activity

        // hermit-myr: donate to Spotlight / Siri (macOS)
#if canImport(CoreSpotlight)
        SpotlightDonor.shared.donate(rfc: rfc)
#endif

        // hermit-iwq: persist for scene restoration on next launch
        appState.persistLastViewedRFC(rfc)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.controllers.removeValue(forKey: rfc.id)
                // hermit-z9j: resign and discard activity when window closes
                self?.activities[rfc.id]?.resignCurrent()
                self?.activities.removeValue(forKey: rfc.id)
                // Clear shared selection when this RFC's window closes
                if appState.selectedRFC?.id == rfc.id {
                    appState.selectedRFC = nil
                    appState.selectedLine = nil
                    // hermit-iwq: clear persisted restore state when window is explicitly closed
                    appState.persistLastViewedRFC(nil)
                }
                // Return to accessory (menu-bar only) mode when all viewer windows are closed.
                if self?.controllers.isEmpty == true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Switch to regular app so the viewer appears in the Dock and Cmd+Tab switcher.
        NSApp.setActivationPolicy(.regular)
    }
}
#endif
