import Foundation

// MARK: - SubmitForReviewSession — state machine for Draft → In Review promotion

@MainActor
final class SubmitForReviewSession: ObservableObject {

    enum Step: String, CaseIterable {
        case idle            = "Idle"
        case ensuringLabel   = "Ensuring label exists…"
        case creatingBranch  = "Creating review branch…"
        case committingFile  = "Committing updated RFC…"
        case openingPR       = "Opening pull request…"
        case success         = "Submitted!"
        case failed          = "Failed"
    }

    @Published var currentStep: Step = .idle
    @Published var errorMessage: String? = nil
    @Published var result: SubmitForReviewResult? = nil
    @Published var progress: Double = 0   // 0–1

    private let client: any HermitClientProtocol

    init(client: any HermitClientProtocol) {
        self.client = client
    }

    // MARK: - Submit

    /// Calls the single submit-for-review endpoint on the Go backend.
    /// The server handles label ensure + branch + commit + PR atomically.
    func submit(rfcID: String) async {
        errorMessage = nil
        result = nil

        advance(to: .ensuringLabel, progress: 0.1)

        do {
            // Single backend call — progress steps mirror the server's work.
            advance(to: .creatingBranch, progress: 0.3)
            advance(to: .committingFile, progress: 0.6)
            advance(to: .openingPR, progress: 0.8)

            let pr = try await client.submitForReview(rfcID: rfcID)
            result = pr
            advance(to: .success, progress: 1.0)
        } catch {
            errorMessage = error.localizedDescription
            currentStep = .failed
        }
    }

    func reset() {
        currentStep = .idle
        errorMessage = nil
        result = nil
        progress = 0
    }

    // MARK: - Private

    private func advance(to step: Step, progress: Double) {
        currentStep = step
        self.progress = progress
    }
}
