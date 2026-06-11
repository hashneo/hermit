import SwiftUI
#if os(macOS)
import AppKit

// MARK: - hermit-noc: NSStatusItem / AppDelegate / popover / LSUIElement
// (AppDelegate approach — registered via HermitNativeApp MenuBarExtra scene)

// NOTE: macOS menu bar is handled declaratively via MenuBarExtra in HermitNativeApp.swift.
// This file adds macOS-specific window management helpers.

// MARK: - hermit-rsf: MenuBarPopover — RFC list sidebar + WKWebView detail

struct MenuBarRFCBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var repoStore    = RepositoryStore.shared
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var serverMgr    = EmbeddedServerManager.shared
    @StateObject private var store = RFCStore()
    @State private var selectedRFC: RFC? = nil
    @State private var showNewRFC = false
    // hermit-d42: owned here so the NavigationSplitView sidebar can be
    // controlled by RFCDetailView's reading-mode toggle.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isReadingMode = false

    /// Stable identity for the current (account, repo, server-port) triple.
    /// Changing any of these fires a new `.task`, reconfigures the client, and reloads.
    private var activeKey: String {
        let acct = accountStore.connections.first?.id.uuidString ?? "none"
        let repo = repoStore.repositories.first?.id.uuidString ?? "none"
        let port = serverMgr.port.map(String.init) ?? "down"
        return "\(acct)-\(repo)-\(port)"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RFCListView(rfcs: store.rfcs, selectedRFC: $selectedRFC) {
                await store.load()
            }
            .navigationTitle("Hermit")
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem {
                    Button { Task { await store.load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh RFCs")
                }
                ToolbarItem {
                    Button { showNewRFC = true } label: {
                        Image(systemName: "plus")
                    }
                    .help("New RFC")
                }
            }
        } detail: {
            if let rfc = selectedRFC {
                RFCDetailView(rfc: rfc, onMerged: {
                    selectedRFC = nil
                    Task { await store.load() }
                }, isReadingMode: $isReadingMode, hasSidebar: true)
            } else {
                ContentUnavailableView("Select an RFC", systemImage: "doc.text")
            }
        }
        // hermit-d42: sync isReadingMode ↔ columnVisibility so the sidebar
        // actually hides/shows when the toolbar button is pressed.
        .onChange(of: isReadingMode) { _, reading in
            withAnimation {
                columnVisibility = reading ? .detailOnly : .all
            }
        }
        .onChange(of: columnVisibility) { _, vis in
            // If the user restores the sidebar via swipe or drag, clear reading mode.
            if vis != .detailOnly && isReadingMode {
                isReadingMode = false
            }
        }
        .frame(width: 780, height: 540)
        .sheet(isPresented: $showNewRFC) {
            NavigationStack {
                RFCInterviewView(aiProvider: AIProviderFactory.makeProvider())
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showNewRFC = false }
                        }
                    }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .task(id: activeKey) {
            selectedRFC = nil
            guard serverMgr.port != nil else { return }  // server still restarting
            let docsPath = repoStore.repositories.first?.docsPath ?? appState.docsPath
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: docsPath)
            }
            await store.load()
        }
    }
}

// MARK: - hermit-2h9: Global keyboard shortcut ⌘⇧H
// Handled in MenuBarExtra; NSEvent monitor for app-wide shortcut:

final class GlobalShortcutMonitor {
    static let shared = GlobalShortcutMonitor()
    private var monitor: Any?
    var onActivate: (() -> Void)?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘⇧H
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "h" {
                DispatchQueue.main.async { self?.onActivate?() }
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - hermit-u63: Pin/detach popover to floating NSPanel

final class FloatingPanelManager {
    static let shared = FloatingPanelManager()
    private var panel: NSPanel?

    func detach(contentView: NSView) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Hermit"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() { panel?.close(); panel = nil }
}

// MARK: - hermit-nag: Background RFC polling with configurable interval and badge

@MainActor
final class RFCPollingService: ObservableObject {
    @Published var unreadCount: Int = 0

    private var task: Task<Void, Never>?
    var intervalSeconds: TimeInterval = 300  // 5 min default
    var onNewRFCs: (([RFC]) -> Void)?

    private var lastKnownIDs: Set<String> = []
    private var store: RFCStore?

    func start(store: RFCStore) {
        self.store = store
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard let store = self.store else { continue }
                let before = Set(store.rfcs.map(\.id))
                await store.load()
                let after = Set(store.rfcs.map(\.id))
                let newIDs = after.subtracting(before)
                if !newIDs.isEmpty {
                    let newRFCs = store.rfcs.filter { newIDs.contains($0.id) }
                    self.unreadCount += newRFCs.count
                    self.onNewRFCs?(newRFCs)
                    NSApp.dockTile.badgeLabel = self.unreadCount > 0 ? "\(self.unreadCount)" : nil
                }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    func clearBadge() { unreadCount = 0; NSApp.dockTile.badgeLabel = nil }
}

#endif
