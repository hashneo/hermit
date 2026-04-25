import SwiftUI

#if os(iOS)
/// iPad root: shows SetupView until discovered, then the RFC browser.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if isReady {
            iPadRootView()
        } else {
            SetupView()
        }
    }

    private var isReady: Bool {
        if appState.isAuthenticated { return true }
        if case .localNetwork = appState.serverMode {
            return !appState.localNetworkToken.isEmpty && !appState.serverBaseURL.isEmpty
        }
        return false
    }
}
#endif
