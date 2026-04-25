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
    @StateObject private var store = RFCStore()
    @State private var selectedRFC: RFC? = nil

    var body: some View {
        NavigationSplitView {
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
                    NavigationLink {
                        RFCInterviewView(aiProvider: AIProviderFactory.makeProvider())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New RFC")
                }
            }
        } detail: {
            if let rfc = selectedRFC {
                RFCDetailView(rfc: rfc)
            } else {
                ContentUnavailableView("Select an RFC", systemImage: "doc.text")
            }
        }
        .frame(width: 780, height: 540)
        .task { await store.load() }
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
