import Foundation
import Combine

// MARK: - RecentRFCEntry

/// Lightweight snapshot of an RFC that was opened — persisted in UserDefaults.
/// Stores just enough to show a title in the menu and reopen the window.
struct RecentRFCEntry: Identifiable, Codable, Equatable {
    let id: String        // RFC.id (SHA)
    let title: String
    let path: String
    let repoID: UUID      // RepositoryStore.Repository.id
}

// MARK: - RecentRFCStore

/// Tracks the last N RFCs opened across all repos.
/// Call `record(_:repoID:)` from RFCViewerWindowManager whenever a viewer opens.
@MainActor
final class RecentRFCStore: ObservableObject {
    static let shared = RecentRFCStore()

    private static let defaultsKey = "hermit.recentRFCs"
    private static let maxCount    = 10

    @Published private(set) var recents: [RecentRFCEntry] = []

    private init() {
        load()
    }

    // MARK: - Public API

    func record(_ rfc: RFC, repoID: UUID) {
        let entry = RecentRFCEntry(id: rfc.id, title: rfc.title, path: rfc.path, repoID: repoID)
        // Move to front, de-duplicate by id.
        recents.removeAll { $0.id == entry.id }
        recents.insert(entry, at: 0)
        if recents.count > Self.maxCount {
            recents = Array(recents.prefix(Self.maxCount))
        }
        save()
    }

    func remove(_ entry: RecentRFCEntry) {
        recents.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        recents = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([RecentRFCEntry].self, from: data) else {
            return
        }
        recents = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
