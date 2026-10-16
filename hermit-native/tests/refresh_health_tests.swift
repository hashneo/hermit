import Foundation

@main
struct RefreshHealthTests {
    static func main() {
        func auth(_ state: RepositoryAuthState, successfulAt: String? = nil) -> RepositoryAuthStatus {
            RepositoryAuthStatus(state: state, method: "pat", lastValidatedAt: nil,
                                 lastSuccessfulRefreshAt: successfulAt, lastAttemptedRefreshAt: nil,
                                 lastErrorCode: nil, lastErrorMessage: nil, remediation: nil)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cached = Date(timeIntervalSince1970: 1_000_000_000)
        let serverDate = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        for state: RepositoryAuthState in [.authenticationRequired, .accessDenied, .refreshFailed] {
            let failure = auth(state)
            precondition(failure.hasRefreshFailure, "Cached HTTP success must preserve failed refresh state")
            precondition(failure.successfulRefreshDate(observedAt: now, cachedAt: cached) == cached)
            precondition(failure.successfulRefreshDate(observedAt: now, cachedAt: nil) == nil,
                         "Never fabricate a successful sync for a repository with no baseline")
            precondition(auth(state, successfulAt: "invalid").successfulRefreshDate(observedAt: now, cachedAt: cached) == cached)
            precondition(auth(state, successfulAt: "2026-01-01T00:00:00Z").successfulRefreshDate(observedAt: now, cachedAt: cached) == serverDate)
        }
        precondition(auth(.authenticationRequired).isCredentialIssue)
        precondition(auth(.accessDenied).isCredentialIssue)
        precondition(!auth(.refreshFailed).isCredentialIssue)
        for state: RepositoryAuthState in [.healthy, .unknown] {
            precondition(!auth(state).hasRefreshFailure)
            precondition(auth(state).successfulRefreshDate(observedAt: now, cachedAt: cached) == now)
        }
        let fractional = auth(.healthy, successfulAt: "2026-01-01T00:00:00.125Z")
        precondition(fractional.successfulRefreshDate(observedAt: now, cachedAt: nil) == serverDate.addingTimeInterval(0.125),
                     "Healthy cache responses must retain the server refresh time, including fractional seconds")
        precondition(RepositoryAuthState(fromRaw: "future_state") == .unknown)
        print("Native refresh-health model tests passed")
    }
}
