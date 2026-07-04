import SwiftUI

/// Placeholder RFC browser — populated by hermit-vj3 / hermit-3dc tasks.
struct RFCBrowserView: View {
    var body: some View {
        NavigationSplitView {
            Text("RFC List")
                .foregroundStyle(.secondary)
        } detail: {
            ContentUnavailableView("Select an RFC", systemImage: "doc.text")
        }
    }
}
