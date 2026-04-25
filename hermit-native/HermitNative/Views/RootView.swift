import SwiftUI

/// iPad root: shows SetupView until discovered, then the RFC browser.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
#if os(iOS)
    @EnvironmentObject private var pairingBrowser: PairingBrowser
#endif

    var body: some View {
        if isReady {
            iPadRootView()
        } else {
            SetupView()
        }
    }

    private var isReady: Bool {
        // GitHub-authed path
        if appState.isAuthenticated { return true }
        // Local-network path: enter the RFC browser as soon as a Mac is
        // discovered (serverBaseURL set by mDNS). The user can pair from
        // the gear menu inside the browser; we don't gate on the token here
        // so a reinstall doesn't leave them stranded on SetupView.
        if case .localNetwork = appState.serverMode {
            return !appState.serverBaseURL.isEmpty
        }
        // Also let them in if a token is already loaded from Keychain even
        // if the Mac hasn't been re-discovered yet (handles backgrounded app).
        if !appState.localNetworkToken.isEmpty && !appState.serverBaseURL.isEmpty {
            return true
        }
        return false
    }
}
