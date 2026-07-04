import Foundation

// MARK: - hermit-999: NSUserActivity type constants and payload helpers

enum HermitActivity {
    /// Activity type for Handoff between Mac and iPad (registered in Info.plist).
    static let handoff = "me.steven.hermit.handoff"
    /// Activity type for scene restoration on relaunch (registered in Info.plist).
    static let viewRFC = "me.steven.hermit.view-rfc"

    // MARK: Payload keys
    static let keyRFCID        = "rfcID"
    static let keyRFCTitle     = "rfcTitle"
    static let keyRFCPath      = "rfcPath"
    static let keySelectedLine = "selectedLine"

    /// Build the userInfo dictionary for an RFC-view activity.
    static func userInfo(for rfc: RFC, selectedLine: Int?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            keyRFCID:    rfc.id,
            keyRFCTitle: rfc.title,
            keyRFCPath:  rfc.path,
        ]
        if let line = selectedLine { info[keySelectedLine] = line }
        return info
    }

    // MARK: - hermit-txn: Deep link URL parsing

    /// Parses a `hermit://rfc/<encoded-path>` URL and returns the decoded RFC path,
    /// or `nil` if the URL does not match the expected format.
    ///
    /// Examples:
    ///   hermit://rfc/docs-cms%2Frfcs%2Frfc-001.md  → "docs-cms/rfcs/rfc-001.md"
    ///   hermit://rfc/rfc-002-my-design.md           → "rfc-002-my-design.md"
    static func rfcPath(from url: URL) -> String? {
        guard url.scheme == "hermit",
              url.host == "rfc" else { return nil }
        // path starts with "/" — drop the leading slash, then percent-decode
        let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }
}
