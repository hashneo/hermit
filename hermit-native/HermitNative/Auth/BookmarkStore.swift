import Foundation

// MARK: - BookmarkStore
//
// Persists a security-scoped bookmark for the Hermit repo root so the
// sandboxed macOS app can re-access it across launches without presenting
// NSOpenPanel every time.
//
// Usage:
//   BookmarkStore.shared.save(url)   // after user picks folder via NSOpenPanel
//   BookmarkStore.shared.resolve()   // returns the URL (starts access)
//   BookmarkStore.shared.clear()     // forget the bookmark

#if os(macOS)

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let key = "hermit.repoRootBookmark"
    private var activeURL: URL?

    private init() {}

    // MARK: - Save

    /// Persist a security-scoped bookmark for `url`.
    /// Call this immediately after the user selects a folder in NSOpenPanel.
    func save(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("[BookmarkStore] Failed to create bookmark: \(error)")
        }
    }

    // MARK: - Resolve

    /// Resolve the persisted bookmark and start accessing it.
    /// Returns the URL on success, nil if no bookmark is stored or it is stale.
    /// Caller must call `stopAccessing()` when done (or call `clear()`).
    func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Refresh the bookmark so it doesn't degrade further.
                save(url)
            }
            guard url.startAccessingSecurityScopedResource() else {
                print("[BookmarkStore] startAccessingSecurityScopedResource failed")
                return nil
            }
            activeURL = url
            return url
        } catch {
            print("[BookmarkStore] Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    // MARK: - Stop access

    /// Stop accessing the security-scoped URL returned by `resolve()`.
    func stopAccessing() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }

    // MARK: - Clear

    /// Remove the stored bookmark (e.g. when user changes the repo location).
    func clear() {
        stopAccessing()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Convenience: hasBookmark

    var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }
}

#endif
