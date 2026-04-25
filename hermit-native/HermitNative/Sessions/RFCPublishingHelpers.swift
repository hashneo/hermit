import Foundation

// MARK: - hermit-9at: RFC number determination with collision retry
// hermit-cim: Frontmatter enrichment before commit

/// Determines the next available RFC number and enriches frontmatter.
enum RFCPublishingHelpers {

    // MARK: - RFC number determination (hermit-9at)

    static func nextRFCNumber(
        client: any HermitClientProtocol,
        maxRetries: Int = 3
    ) async throws -> Int {
        for attempt in 0..<maxRetries {
            let files = try await client.listMainBranchRFCs()
            let usedNumbers = files.compactMap { rfcNumber(from: $0.name) }
            let candidate = (usedNumbers.max() ?? 0) + 1

            if attempt > 0 {
                let delay = UInt64(attempt) * 500_000_000
                try await Task.sleep(nanoseconds: delay)
            }

            let recheck = try await client.listMainBranchRFCs()
            let recheckNumbers = recheck.compactMap { rfcNumber(from: $0.name) }
            if !recheckNumbers.contains(candidate) {
                return candidate
            }
        }
        throw NumberingError.collisionAfterRetries
    }

    private static func rfcNumber(from filename: String) -> Int? {
        let pattern = #"^rfc-0*(\d+)"#
        guard let range = filename.range(of: pattern, options: .regularExpression),
              let numRange = filename.range(of: #"(\d+)"#, options: .regularExpression,
                                            range: range)
        else { return nil }
        return Int(filename[numRange])
    }

    enum NumberingError: LocalizedError {
        case collisionAfterRetries
        var errorDescription: String? {
            "Could not determine a unique RFC number after several retries. Please try again."
        }
    }

    // MARK: - Frontmatter enrichment (hermit-cim)

    static func enrichFrontmatter(
        markdown: String,
        rfcNumber: Int,
        authorLogin: String
    ) -> String {
        let rfcID = String(format: "rfc-%03d", rfcNumber)
        let created = ISO8601DateFormatter().string(from: Date())
        let docUUID = UUID().uuidString.lowercased()

        let newFields = """
        id: \(rfcID)
        author: \(authorLogin)
        created: \(created)
        doc_uuid: \(docUUID)
        """

        if markdown.hasPrefix("---") {
            let lines = markdown.components(separatedBy: "\n")
            var result: [String] = []
            var closingFound = false
            for (i, line) in lines.enumerated() {
                if i > 0 && line.trimmingCharacters(in: .whitespaces) == "---" && !closingFound {
                    for field in newFields.components(separatedBy: "\n") {
                        let key = field.components(separatedBy: ":").first?
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        let alreadyPresent = result.contains { $0.hasPrefix("\(key):") }
                        if !alreadyPresent { result.append(field) }
                    }
                    closingFound = true
                }
                result.append(line)
            }
            return result.joined(separator: "\n")
        }

        return "---\n\(newFields)\n---\n\n\(markdown)"
    }

    // MARK: - Helpers

    static func branchName(rfcTitle: String, rfcNumber: Int) -> String {
        let slug = rfcTitle
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        return String(format: "rfc/%03d-%@", rfcNumber, slug)
    }

    static func filePath(docsPath: String, rfcNumber: Int, rfcTitle: String) -> String {
        let slug = rfcTitle
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
        let name = String(format: "rfc-%03d-%@.md", rfcNumber, slug)
        return "\(docsPath)/\(name)"
    }
}
