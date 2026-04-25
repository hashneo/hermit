import Foundation

// MARK: - hermit-zb4: PublishingSession — branch → commit → PR state machine

/// Orchestrates the full RFC publishing flow with retry logic.
@MainActor
final class PublishingSession: ObservableObject {

    enum Step: String, CaseIterable {
        case idle         = "Idle"
        case creatingBranch = "Creating branch…"
        case committingFile = "Committing file…"
        case openingPR    = "Opening pull request…"
        case success      = "Published!"
        case failed       = "Failed"
    }

    @Published var currentStep: Step = .idle
    @Published var errorMessage: String? = nil
    @Published var publishedPR: RFCPullRequest? = nil
    @Published var progress: Double = 0  // 0–1

    private let client: GitHubAPIClient
    private let config: GitHubAPIClient.Config
    private let maxRetries = 3

    init(client: GitHubAPIClient, config: GitHubAPIClient.Config) {
        self.client = client
        self.config = config
    }

    // MARK: - Publish

    func publish(
        markdown: String,
        rfcTitle: String,
        authorLogin: String
    ) async {
        errorMessage = nil
        publishedPR = nil

        do {
            // Step 1: determine RFC number
            advance(to: .creatingBranch, progress: 0.1)
            let number = try await RFCPublishingHelpers.nextRFCNumber(client: client)

            // Step 2: enrich frontmatter
            let enriched = RFCPublishingHelpers.enrichFrontmatter(
                markdown: markdown, rfcNumber: number, authorLogin: authorLogin)

            // Step 3: create branch
            let baseSHA = try await withRetry { [weak self] in
                try await self!.client.getMainBranchSHA()
            }
            let branch = RFCPublishingHelpers.branchName(rfcTitle: rfcTitle, rfcNumber: number)
            try await withRetry { [weak self] in
                try await self!.client.createBranch(name: branch, fromSHA: baseSHA)
            }
            advance(to: .committingFile, progress: 0.45)

            // Step 4: commit file
            let path = RFCPublishingHelpers.filePath(
                docsPath: config.docsPath, rfcNumber: number, rfcTitle: rfcTitle)
            let commitMessage = "docs(rfc): add \(String(format: "rfc-%03d", number)) \(rfcTitle)"
            try await withRetry { [weak self] in
                _ = try await self!.client.commitFile(
                    branch: branch, path: path,
                    content: enriched, message: commitMessage)
            }
            advance(to: .openingPR, progress: 0.75)

            // Step 5: open PR
            let prBody = "## \(rfcTitle)\n\nCreated via Hermit native app.\n\n" +
                         "<!-- hermit:rfc-ready -->"
            let pr = try await withRetry { [weak self] in
                try await self!.client.createPR(
                    title: rfcTitle, body: prBody,
                    headBranch: branch, label: self!.config.rfcLabel)
            }

            publishedPR = pr
            advance(to: .success, progress: 1.0)

        } catch {
            errorMessage = error.localizedDescription
            currentStep = .failed
        }
    }

    func reset() {
        currentStep = .idle
        errorMessage = nil
        publishedPR = nil
        progress = 0
    }

    // MARK: - Private

    private func advance(to step: Step, progress: Double) {
        currentStep = step
        self.progress = progress
    }

    private func withRetry<T>(operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                // Don't retry auth or not-found errors
                if case GitHubAPIClient.APIError.unauthorized = error { throw error }
                if case GitHubAPIClient.APIError.notFound = error { throw error }
                let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError!
    }
}
