import Foundation
import Combine

/// Central application state shared across all views via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentRepo: String? = nil

    private let keychain = KeychainHelper.shared

    init() {
        isAuthenticated = keychain.pat != nil
    }
}
