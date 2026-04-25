import SwiftUI

// MARK: - hermit-3dc: NavigationSplitView root layout (iPad)
// hermit-80m: Post-publish RFC list refresh and new RFC highlight
// hermit-l00: RFCStore migrated to HermitClientProtocol

@MainActor
final class RFCStore: ObservableObject {
    @Published var rfcs: [RFC] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var newlyPublishedID: String? = nil  // hermit-80m: highlight after publish

    private var client: (any HermitClientProtocol)?
    // docsPath retained for the resolvePRPath fallback that needs the path prefix
    private var docsPath: String = "docs-cms/rfcs"

    func configure(client: any HermitClientProtocol, docsPath: String) {
        self.client   = client
        self.docsPath = docsPath
    }

    func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (mainFiles, prs) = try await client.discoverRFCs()
            var result: [RFC] = mainFiles.map {
                RFC(id: $0.id, title: titleFromFilename($0.name),
                    path: $0.path, sha: $0.sha, source: .mainBranch)
            }
            for pr in prs {
                let path = await resolvePRPath(client: client, pr: pr)
                result.append(RFC(id: "pr-\(pr.id)", title: pr.title,
                                  path: path, sha: pr.headSHA,
                                  source: .pullRequest(pr)))
            }
            rfcs = result.sorted { $0.title < $1.title }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Returns the RFC .md path for a PR: prefers the file the PR actually changed,
    /// falling back to the first .md file on the head branch.
    private func resolvePRPath(client: any HermitClientProtocol, pr: RFCPullRequest) async -> String {
        do {
            let changed = try await client.listPRChangedFiles(prNumber: pr.number, docsPath: docsPath)
            if let path = changed.first { return path }
            let files = try await client.listFilesOnRef(docsPath: docsPath, ref: pr.headRef)
            return files.first ?? ""
        } catch {
            return ""
        }
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
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = RFCStore()
    @StateObject private var commentStore = CommentStore()
    @State private var selectedRFC: RFC? = nil
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedLine: Int? = nil

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
                RFCDetailView(rfc: rfc, commentStore: commentStore, onLineTapped: { line in
                    selectedLine = line
                })
            } else {
                ContentUnavailableView("Select an RFC", systemImage: "doc.text")
            }
        } detail: {
            if let rfc = selectedRFC, case .pullRequest(let pr) = rfc.source {
                ThreadPanelView(prNumber: pr.number, selectedLine: selectedLine)
                    .environmentObject(commentStore)
            } else if selectedRFC != nil {
                ContentUnavailableView("Main-branch RFC", systemImage: "doc.text",
                    description: Text("Comments are only available on PR branches."))
            } else {
                ContentUnavailableView("Select an RFC", systemImage: "bubble.left")
            }
        }
        .task {
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: appState.docsPath)
            }
            await store.load()
        }
    }
}
