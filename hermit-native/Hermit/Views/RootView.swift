import SwiftUI

/// iPad root: shows pairing discovery until connected, then the RFC browser.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
#if os(iOS)
    @EnvironmentObject private var pairingBrowser: PairingBrowser
#endif

    var body: some View {
#if os(iOS)
        if isReady {
            iPadRootView()
        } else {
            // Local-network mode: show Mac discovery / pairing screen.
            // SetupView (URL + PAT) is only for direct/remote server connections.
            iPadPairingView()
        }
#endif
    }

    private var isReady: Bool {
        // GitHub-authed path
        if appState.isAuthenticated { return true }
#if os(iOS)
        // Paired path: token on hand → RFC browser.
        // This is the primary gate — both discovered AND paired required.
        if pairingBrowser.isPaired { return true }
        // Not paired → always show pairing screen so the user can pair,
        // even if the Mac has been discovered via mDNS.
        return false
#else
        if case .localNetwork = appState.serverMode {
            return !appState.serverBaseURL.isEmpty
        }
        if !appState.localNetworkToken.isEmpty && !appState.serverBaseURL.isEmpty {
            return true
        }
        return false
#endif
    }
}
