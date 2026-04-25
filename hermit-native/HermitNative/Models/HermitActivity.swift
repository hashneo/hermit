import Foundation

// MARK: - hermit-999: NSUserActivity type constants and payload helpers

enum HermitActivity {
    /// Activity type for Handoff between Mac and iPad (registered in Info.plist).
    static let handoff = "com.hashicorp.hermit.handoff"
    /// Activity type for scene restoration on relaunch (registered in Info.plist).
    static let viewRFC = "com.hashicorp.hermit.view-rfc"

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
}
