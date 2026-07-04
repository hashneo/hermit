import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight

// MARK: - hermit-myr: Spotlight / Siri donation for viewed RFCs

/// Indexes recently viewed RFCs into CoreSpotlight so they appear in
/// Spotlight search and Siri suggestions.
///
/// Call `SpotlightDonor.shared.donate(rfc:)` whenever an RFC is opened.
/// The index entry is keyed on the RFC id; re-donating the same RFC is safe
/// and simply refreshes the metadata.
@MainActor
final class SpotlightDonor {
    static let shared = SpotlightDonor()

    private let index = CSSearchableIndex.default()
    private let domainIdentifier = "com.hashicorp.hermit.rfcs"

    /// Donate an RFC to Spotlight / Siri so it appears in search results.
    func donate(rfc: RFC) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = rfc.title
        attributeSet.contentDescription = rfc.path

        let item = CSSearchableItem(
            uniqueIdentifier: "hermit-rfc-\(rfc.id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        // Keep entries for 30 days; Spotlight will expire them automatically
        item.expirationDate = Date(timeIntervalSinceNow: 30 * 24 * 3600)

        index.indexSearchableItems([item]) { error in
            if let error {
                // Non-fatal — Spotlight donation is best-effort
                print("[SpotlightDonor] indexing error for \(rfc.id): \(error)")
            }
        }
    }

    /// Remove all Hermit RFC entries from Spotlight (e.g. on sign-out).
    func removeAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }
}
#endif
