import SwiftUI

// MARK: - hermit-3dc: NavigationSplitView root layout (iPad)
// hermit-80m: Post-publish RFC list refresh and new RFC highlight

@MainActor
final class RFCStore: ObservableObject {
    @Published var rfcs: [RFC] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var newlyPublishedID: String? = nil  // hermit-80m: highlight after publish

    private var client: GitHubAPIClient?
    private var config: GitHubAPIClient.Config?

    func configure(client: GitHubAPIClient, config: GitHubAPIClient.Config) {
        self.client = client
        self.config = config
    }

    func load() async {
        guard let client, let _ = config else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (mainFiles, prs) = try await client.discoverRFCs()
            var result: [RFC] = mainFiles.map {
                RFC(id: $0.id, title: titleFromFilename($0.name),
                    path: $0.path, sha: $0.sha, source: .mainBranch)
            }
            for pr in prs {
                result.append(RFC(id: "pr-\(pr.id)", title: pr.title,
                                  path: "", sha: pr.headSHA,
                                  source: .pullRequest(pr)))
            }
            rfcs = result.sorted { $0.title < $1.title }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// hermit-80m: refresh after publish and surface the new RFC
    func refreshAfterPublish(prNumber: Int) async {
        await load()
        newlyPublishedID = rfcs.first {
            if case .pullRequest(let pr) = $0.source { return pr.number == prNumber }
            return false
        }?.id
    }

    private func titleFromFilename(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

struct iPadRootView: View {
    @StateObject private var store = RFCStore()
    @State private var selectedRFC: RFC? = nil
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedText: String? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RFCListView(rfcs: store.rfcs, selectedRFC: $selectedRFC) {
                await store.load()
            }
            .navigationTitle("Hermit")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
            }
        } content: {
            if let rfc = selectedRFC {
                RFCDetailView(rfc: rfc, onTextSelected: { text in
                    selectedText = text
                })
            } else {
                ContentUnavailableView("Select an RFC", systemImage: "doc.text")
            }
        } detail: {
            if let text = selectedText, let rfc = selectedRFC,
               case .pullRequest(let pr) = rfc.source {
                ThreadPanelView(prNumber: pr.number, selectedText: text)
            } else {
                ContentUnavailableView("Select text to comment", systemImage: "bubble.left")
            }
        }
        .task { await store.load() }
    }
}
