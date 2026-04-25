import SwiftUI

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
