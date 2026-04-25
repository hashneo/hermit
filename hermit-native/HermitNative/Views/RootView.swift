import SwiftUI

/// iPad root: shows SetupView on first launch, then the main RFC browser.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isAuthenticated {
            RFCBrowserView()
        } else {
            SetupView()
        }
    }
}
