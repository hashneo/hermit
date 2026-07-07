import SwiftUI
#if os(macOS)
import AppKit
import Combine
#endif

// MARK: - hermit-y9x: Wire EmbeddedServerManager at app launch (macOS)

@main
struct HermitApp: App {
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
        // The Settings window is used by both modes:
        // - native menu mode: opened via ⌘, or the "Settings…" menu item
        // - popup mode: Settings is also accessible inline inside the dashboard panel
        Settings {
            SettingsView()
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
    private var menuBarStyleObserver: NSObjectProtocol?
    private var menuBarController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the menu bar controller in whichever style the user has configured.
        // Defaults to .nativeMenu on a clean install.
        let menuBarController = MenuBarStatusItemController()
        self.menuBarController = menuBarController
        menuBarController.start()

        // Watch for preference changes and switch modes immediately without a restart.
        menuBarStyleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // One run-loop hop so any in-flight UI updates settle first.
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    guard let self, let controller = self.menuBarController else { return }
                    let newStyle = ConfigStore.shared.menuBarStyle
                    controller.switchMode(to: newStyle)
                }
            }
        }

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
        menuBarController?.stop()
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
            // Start the embedded server unconditionally.  buildConfigJSON reads
            // AccountStore + RepositoryStore directly, so the server starts with
            // whatever repos are configured — or with an empty repo list if none
            // are set up yet.  Repository and account config is handled entirely
            // through Settings; the old GiteaAutoConfig folder-picker gate is no
            // longer needed and was blocking startup after a config wipe.
            HermitApp.startEmbeddedServer(appState: appState)
        }
    }
}

extension HermitApp {
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
        // Load paired tokens BEFORE starting the server so buildConfigJSON
        // includes them and the Go server's LocalNetworkAuth is populated
        // from the first request — iPad doesn't get a spurious 401 on startup.
        PairedTokenStore.shared.load()
        EmbeddedServerManager.shared.start(appState: appState)
        if let port = EmbeddedServerManager.shared.port {
            ConfigStore.shared.serverBaseURL = "http://127.0.0.1:\(port)"
        }
    }
}

@MainActor
final class RFCViewerWindowManager {
    static let shared = RFCViewerWindowManager()
    private var controllers: [String: NSWindowController] = [:]
    // hermit-z9j: one donated activity per open RFC window
    private var activities: [String: NSUserActivity] = [:]

    func open(rfc: RFC, repo: Repository, appState: AppState) {
        // hermit-olq: track selection in AppState for NSUserActivity access
        appState.selectedRFC = rfc
        appState.selectedLine = nil

        if let existing = controllers[rfc.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let commentStore = CommentStore()
        let detail = RFCDetailView(rfc: rfc, repo: repo, commentStore: commentStore)
            .environmentObject(appState)
            .environmentObject(commentStore)
            .frame(minWidth: 760, minHeight: 540)

        let hostingController = NSHostingController(rootView: detail)
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = rfc.title
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width  = min(screenSize.width  * 0.50, 1200)
        let height = min(screenSize.height * 0.90, 1080)
        window.setContentSize(NSSize(width: width, height: height))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controllers[rfc.id] = controller

        // Record in recents so the menu bar shows recently opened RFCs.
        RecentRFCStore.shared.record(rfc, repoID: repo.id)

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
                // Defer the policy change by one run-loop tick so the MenuBarExtra scene
                // is not torn down while SwiftUI is still reconciling window state.
                // Immediate setActivationPolicy(.accessory) is a known cause of MenuBarExtra
                // disappearing on macOS when called synchronously during a window-close event.
                if self?.controllers.isEmpty == true {
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Switch to regular app so the viewer appears in the Dock and Cmd+Tab switcher.
        // Defer by one run-loop tick — calling setActivationPolicy synchronously here
        // causes the MenuBarExtra to disappear on macOS when an RFC window is opened
        // while the app is in .accessory mode (e.g. triggered by an iPad Handoff).
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var nativeMenu: HermitNativeMenu?
    private var currentMode: MenuBarStyle = .nativeMenu

    func start() {
        currentMode = ConfigStore.shared.menuBarStyle
        setupIcon()
        configureForMode(currentMode)
        Self.log("status item started in mode=\(currentMode.rawValue)")
    }

    /// Tears down the current mode and switches to the new one immediately.
    func switchMode(to style: MenuBarStyle) {
        guard style != currentMode else { return }
        Self.log("switching mode \(currentMode.rawValue) → \(style.rawValue)")
        tearDownCurrentMode()
        currentMode = style
        configureForMode(style)
    }

    func stop() {
        tearDownCurrentMode()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Private

    private func setupIcon() {
        statusItem.button?.toolTip = "Hermit"
        updateIcon(hasPendingInvitation: PairingAdvertiser.shared.pendingInvitation != nil)
        PairingAdvertiser.shared.$pendingInvitation
            .receive(on: RunLoop.main)
            .sink { [weak self] invite in
                self?.updateIcon(hasPendingInvitation: invite != nil)
            }
            .store(in: &cancellables)
    }

    private func configureForMode(_ mode: MenuBarStyle) {
        guard let button = statusItem.button else { return }
        switch mode {
        case .nativeMenu:
            // Attach a real NSMenu — macOS handles click-to-show automatically.
            button.action = nil
            button.target = nil
            button.sendAction(on: [])
            let menu = HermitNativeMenu()
            nativeMenu = menu
            statusItem.menu = menu
        case .popup:
            // Remove any attached NSMenu so clicks reach our action handler.
            statusItem.menu = nil
            nativeMenu = nil
            button.isEnabled = true
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            installClickMonitors()
        }
    }

    private func tearDownCurrentMode() {
        closePanel()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        statusItem.menu = nil
        nativeMenu = nil
        guard let button = statusItem.button else { return }
        button.action = nil
        button.target = nil
        button.sendAction(on: [])
    }

    // MARK: - Popup panel

    @objc private func togglePanel(_ sender: Any?) {
        Self.log("status item clicked; visible=\(panel?.isVisible == true)")
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let content = MenuBarContentView(
            anchorScreenX: screenRect.midX,
            onOpenReview: { [weak self] in
                self?.closePanel()
            },
            onDetach: { [weak self] in
                DashboardFloatingWindowManager.shared.open(appState: AppState.shared)
                self?.closePanel()
            },
            onClose: { [weak self] in
                self?.closePanel()
            }
        )
            .environmentObject(AppState.shared)
        let hosting = NSHostingController(rootView: content)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let initialFrame = NSRect(
            x: screenRect.midX - 280,
            y: screenRect.minY - 486,
            width: 560,
            height: 486
        )
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.panel = panel
        panel.orderFrontRegardless()
        installClickMonitors()
        Self.log("panel opened; statusRect=\(screenRect) initialFrame=\(initialFrame)")
    }

    private func closePanel() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        Self.log("panel closed")
    }

    private func installClickMonitors() {
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    self?.closeIfClickIsOutsidePanel()
                }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                Task { @MainActor in
                    self?.closeIfClickIsOutsidePanel()
                }
                return event
            }
        }
    }

    private func closeIfClickIsOutsidePanel() {
        guard let panel,
              panel.isVisible,
              !panel.frame.contains(NSEvent.mouseLocation),
              !statusItemFrameContainsMouse() else { return }
        closePanel()
    }

    private func statusItemFrameContainsMouse() -> Bool {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return false }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        return screenRect.contains(NSEvent.mouseLocation)
    }

    private func updateIcon(hasPendingInvitation: Bool) {
        let symbolName = hasPendingInvitation ? "person.crop.circle.badge.exclamationmark" : "doc.text.magnifyingglass"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Hermit")
    }

    private static func log(_ message: String) {
        let line = "[\(Date())] [MenuBarStatusItemController] \(message)\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-native-debug.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

// MARK: - Native NSMenu (native menu mode)

/// Builds the top-level NSMenu shown when menuBarStyle == .nativeMenu.
/// Uses NSMenuDelegate.menuNeedsUpdate to rebuild items before each display,
/// keeping server status and repo list current without polling.
@MainActor
final class HermitNativeMenu: NSMenu, NSMenuDelegate {
    private var repoSubmenus: [UUID: HermitRepoSubMenu] = [:]

    override init(title: String = "") {
        super.init(title: title)
        self.delegate = self
        self.autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("not implemented") }

    // Called just before the menu is displayed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        buildItems()
    }

    private func buildItems() {
        removeAllItems()

        // ── Pairing invitation ─────────────────────────────────────────
        if let invite = PairingAdvertiser.shared.pendingInvitation {
            addDisabledItem("\(invite.peerName) wants to pair")
            addItem(makeItem("Allow", action: #selector(allowPairing)))
            addItem(makeItem("Deny",  action: #selector(denyPairing)))
            addItem(.separator())
        }

        // ── Server status ──────────────────────────────────────────────
        let serverMgr = EmbeddedServerManager.shared
        let statusText: String
        if let port = serverMgr.port        { statusText = "Server running · port \(port)" }
        else if serverMgr.errorMessage != nil { statusText = "Server error — check Settings" }
        else                                   { statusText = "Server starting…" }
        addDisabledItem(statusText)
        addItem(.separator())

        // ── Per-repo submenus ──────────────────────────────────────────
        let repos = RepositoryStore.shared.repositories
        if repos.isEmpty {
            addDisabledItem("No repositories configured")
        } else {
            for repo in repos {
                let item = NSMenuItem(title: repo.fullName, action: nil, keyEquivalent: "")
                item.submenu = cachedSubmenu(for: repo)
                addItem(item)
            }
        }
        addItem(.separator())

        // ── Actions ───────────────────────────────────────────────────
        addItem(makeItem("Open Dashboard…", action: #selector(openDashboard)))
        addItem(makeItem("Refresh All",     action: #selector(refreshAll)))
        addItem(.separator())
        let settings = makeItem("Settings…", action: #selector(openSettings), key: ",")
        settings.keyEquivalentModifierMask = .command
        addItem(settings)
        let quit = NSMenuItem(title: "Quit Hermit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = NSApp
        addItem(quit)
    }

    // MARK: - Helpers

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func cachedSubmenu(for repo: Repository) -> HermitRepoSubMenu {
        if let existing = repoSubmenus[repo.id] { return existing }
        let sub = HermitRepoSubMenu(repo: repo)
        repoSubmenus[repo.id] = sub
        return sub
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        DashboardFloatingWindowManager.shared.open(appState: AppState.shared)
    }

    @objc private func refreshAll() {
        RepoRFCCache.shared.invalidateAll()
        repoSubmenus.removeAll()
    }

    @objc private func openSettings() {
        DashboardFloatingWindowManager.shared.open(appState: AppState.shared, openToSettings: true)
    }

    @objc private func allowPairing() {
        PairingAdvertiser.shared.pendingInvitation?.accept()
    }

    @objc private func denyPairing() {
        PairingAdvertiser.shared.pendingInvitation?.decline()
    }
}

// MARK: - Per-repo submenu

/// Lazy-loading submenu for a single repository.
/// Shows "Loading…" on first open, then populates from cache or a fresh fetch.
/// Updates in-place if the menu is visible when the async load completes.
@MainActor
final class HermitRepoSubMenu: NSMenu, NSMenuDelegate {
    let repo: Repository
    private enum LoadState { case idle, loading, loaded([RFC], [RFC]), failed(String) }
    private var loadState: LoadState = .idle
    private var loadTask: Task<Void, Never>?

    init(repo: Repository) {
        self.repo = repo
        super.init(title: repo.fullName)
        self.delegate = self
        self.autoenablesItems = false
        showLoading()
    }

    required init(coder: NSCoder) { fatalError("not implemented") }

    // Called just before the submenu is displayed.
    func menuWillOpen(_ menu: NSMenu) {
        // Serve from the shared cache if available.
        if let cached = RepoRFCCache.shared.nativeSections(for: repo.id) {
            if case .loaded = loadState {} else {
                loadState = .loaded(cached.mainBranch, cached.pullRequests)
            }
        }
        switch loadState {
        case .idle:    showLoading(); startLoad()
        case .loading: break
        case .loaded(let main, let prs): populate(main: main, prs: prs)
        case .failed(let msg):           showError(msg)
        }
    }

    // MARK: - Display states

    private func showLoading() {
        removeAllItems()
        addDisabledItem("Loading…")
    }

    private func populate(main: [RFC], prs: [RFC]) {
        removeAllItems()
        if main.isEmpty && prs.isEmpty {
            addDisabledItem("No RFCs")
        } else {
            // ── In Review first ────────────────────────────────────────
            if !prs.isEmpty {
                addDisabledItem("In Review")
                for rfc in prs { addItem(rfcItem(rfc, systemImage: "arrow.triangle.pull")) }
                if !main.isEmpty { addItem(.separator()) }
            }
            // ── Main branch: grouped by lifecycle status ───────────────
            let groups = RFCStatusGroup.group(main)
            let nonEmpty = groups.filter { !$0.rfcs.isEmpty }
            for (i, group) in nonEmpty.enumerated() {
                if i > 0 { addItem(.separator()) }
                addDisabledItem(group.header)
                for rfc in group.rfcs { addItem(rfcItem(rfc, systemImage: group.systemImage)) }
            }
        }
        addItem(.separator())
        addItem(makeItem("Refresh", action: #selector(refreshRepo)))
    }

    private func showError(_ msg: String) {
        removeAllItems()
        addDisabledItem("Failed to load")
        addDisabledItem(msg)
        addItem(.separator())
        addItem(makeItem("Retry", action: #selector(refreshRepo)))
    }

    // MARK: - Loading

    private func startLoad() {
        loadState = .loading
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let client = AppState.shared.makeAPIClient(for: self.repo) else {
                self.loadState = .failed("No API client")
                self.showError("No API client")
                return
            }
            do {
                let (mainFiles, prs, _) = try await client.discoverRFCs()
                let mainRFCs = mainFiles.map {
                    RFC(id: $0.id, title: $0.name, path: $0.path,
                        sha: $0.sha, source: .mainBranch,
                        lifecycleStatus: $0.lifecycleStatus, htmlURL: $0.htmlURL)
                }.sorted { $0.title < $1.title }

                // One entry per PR: deduplicate to the primary RFC document.
                let primaryPRs = primaryPRDocuments(from: prs)

                let prRFCs = primaryPRs.map {
                    RFC(id: "pr-\($0.number)", title: $0.prTitle.isEmpty ? $0.title : $0.prTitle,
                        path: $0.documentPath, sha: $0.headSHA, source: .pullRequest($0),
                        lifecycleStatus: nil, htmlURL: $0.htmlURL)
                }.sorted { $0.title < $1.title }
                guard !Task.isCancelled else { return }
                self.loadState = .loaded(mainRFCs, prRFCs)
                self.populate(main: mainRFCs, prs: prRFCs)
            } catch {
                guard !Task.isCancelled else { return }
                self.loadState = .failed(error.localizedDescription)
                self.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func rfcItem(_ rfc: RFC, systemImage: String = "doc.text") -> NSMenuItem {
        let item = NSMenuItem(title: rfc.title, action: #selector(openRFC(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = rfc
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openRFC(_ sender: NSMenuItem) {
        guard let rfc = sender.representedObject as? RFC else { return }
        RecentRFCStore.shared.record(rfc, repoID: repo.id)
        RFCViewerWindowManager.shared.open(rfc: rfc, repo: repo, appState: AppState.shared)
    }

    @objc private func refreshRepo() {
        loadState = .idle
        loadTask?.cancel()
        RepoRFCCache.shared.invalidateAll()
        showLoading()
        startLoad()
    }
}

final class DashboardFloatingWindowManager {
    static let shared = DashboardFloatingWindowManager()
    private var controller: NSWindowController?

    func open(appState: AppState, openToSettings: Bool = false) {
        if let existing = controller?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hermit Dashboard"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 780, height: 580)
        panel.center()

        let content = MenuBarContentView(
            managesWindowPresentation: false,
            allowsDetach: false,
            openToSettings: openToSettings,
            onOpenReview: {},
            onClose: { [weak panel] in panel?.close() }
        )
            .environmentObject(appState)

        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        panel.contentViewController = hosting

        let controller = NSWindowController(window: panel)
        self.controller = controller

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.controller = nil }
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

// MARK: - New RFC Window Manager (macOS)
// Opens a standalone window containing RFCInterviewView.
// Re-uses the existing window if one is already open.

@MainActor
final class NewRFCWindowManager {
    static let shared = NewRFCWindowManager()
    private var controller: NSWindowController?

    func open(appState: AppState) {
        if let existing = controller?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = NavigationStack {
            RFCInterviewView(aiProvider: AIProviderFactory.makeProvider())
        }
        .environmentObject(appState)
        .frame(minWidth: 620, minHeight: 520)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "New RFC"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 560))
        window.center()
        window.isReleasedWhenClosed = false

        let wc = NSWindowController(window: window)
        controller = wc

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.controller = nil }
        }

        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
#endif

// MARK: - Shared PR document filtering (all platforms)

/// Returns the single primary `RFCPullRequest` for each PR in `prs`.
/// Filters to genuine RFC documents (documentType == "rfc", rfc-NNN path),
/// prefers actionable (non-terminal) lifecycle status, and uses the highest
/// RFC number as a tiebreaker so superseded/updated files are not picked over
/// the newly proposed one.
func primaryPRDocuments(from prs: [RFCPullRequest]) -> [RFCPullRequest] {
    Dictionary(grouping: prs, by: { $0.number })
        .values
        .compactMap { group -> RFCPullRequest? in
            let rfcs = group.filter { $0.documentType == "rfc" && isRFCDocumentPath($0.documentPath) }
            guard !rfcs.isEmpty else { return nil }
            let actionable = rfcs.filter { !isTerminalStatus($0.lifecycleStatus) }
            return (actionable.isEmpty ? rfcs : actionable)
                .max(by: { rfcNumberFromPath($0.documentPath) < rfcNumberFromPath($1.documentPath) })
        }
        .sorted { $0.number < $1.number }
}

/// Returns true when `path` points to a genuine RFC document.
/// Matches filenames like `rfc-001-title.md` but rejects index files
/// (`rfc-index.md`), ADRs, PRDs, and any file without a numeric suffix
/// immediately following the `rfc-` prefix.
func isRFCDocumentPath(_ path: String) -> Bool {
    guard let filename = path.split(separator: "/").last.map(String.init) else { return false }
    let lower = filename.lowercased()
    guard lower.hasSuffix(".md"), lower.hasPrefix("rfc-") else { return false }
    return lower.dropFirst(4).first?.isNumber == true
}

/// Extracts the RFC sequence number from a path like `docs-cms/rfcs/rfc-076-title.md` → 76.
func rfcNumberFromPath(_ path: String) -> Int {
    guard let filename = path.split(separator: "/").last.map(String.init) else { return 0 }
    let lower = filename.lowercased()
    guard lower.hasPrefix("rfc-") else { return 0 }
    let digits = lower.dropFirst(4).prefix(while: { $0.isNumber })
    return Int(digits) ?? 0
}

/// Returns true for lifecycle statuses that mean the RFC is no longer actively
/// being proposed — superseded, implemented, or rejected.
func isTerminalStatus(_ status: String?) -> Bool {
    switch status?.lowercased() {
    case "superseded", "implemented", "rejected": return true
    default: return false
    }
}
