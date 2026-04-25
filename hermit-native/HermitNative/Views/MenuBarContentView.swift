import SwiftUI

/// macOS menu bar popover content.
/// Shows SetupView on first launch; main RFC browser once authenticated.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isAuthenticated {
            RFCBrowserView()
                .frame(width: 480, height: 600)
        } else {
            SetupView()
        }
    }
}
