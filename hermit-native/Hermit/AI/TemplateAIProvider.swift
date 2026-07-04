import Foundation

// MARK: - TemplateAIProvider
// A zero-configuration AI provider for local dev and demo.
// Uses the hardcoded stage questions from RFCInterviewPrompts and assembles
// RFC markdown from the interview transcript without any API key.
// Selected automatically by AIProviderFactory when no other provider is available.

final class TemplateAIProvider: AIProvider {
    let displayName = "Template (offline)"

    // MARK: - Chat

    func chat(messages: [AIMessage]) async throws -> String {
        // Simulate a brief thinking delay so the UI doesn't flash
        try await Task.sleep(nanoseconds: 400_000_000)

        let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""

        // Assembly prompt — build real RFC markdown from transcript
        if lastUser.contains("Based on the following interview transcript") {
            return assembleRFC(from: lastUser)
        }

        // Acknowledgement + next question prompt — extract the "ask: <question>" suffix
        if lastUser.contains("Briefly acknowledge") {
            let ack = pickAcknowledgement()
            // Extract the question after "ask: "
            if let range = lastUser.range(of: "ask: ") {
                let question = String(lastUser[range.upperBound...])
                return "\(ack) \(question)"
            }
            return ack
        }

        // Fallback
        return "Got it. Tell me more."
    }

    // MARK: - Transcription (not supported — STT handled by SFSpeechRecognizer)

    func transcribe(audioData: Data, mimeType: String) async throws -> String {
        throw AIError.notConfigured
    }

    // MARK: - Private helpers

    private func pickAcknowledgement() -> String {
        let acks = [
            "Got it.",
            "Thanks, that's helpful.",
            "Understood.",
            "Makes sense.",
            "Great, noted.",
        ]
        return acks[Int.random(in: 0..<acks.count)]
    }

    private func assembleRFC(from prompt: String) -> String {
        // Parse the transcript lines from the prompt
        var title        = "Untitled RFC"
        var problem      = ""
        var proposal     = ""
        var design       = ""
        var drawbacks    = ""
        var alternatives = ""
        var questions    = ""

        let lines = prompt.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("[title]") {
                title = extract(line, prefix: "[title]")
            } else if line.hasPrefix("[problem]") {
                problem = extract(line, prefix: "[problem]")
            } else if line.hasPrefix("[proposal]") {
                proposal = extract(line, prefix: "[proposal]")
            } else if line.hasPrefix("[designDetails]") {
                design = extract(line, prefix: "[designDetails]")
            } else if line.hasPrefix("[drawbacks]") {
                drawbacks = extract(line, prefix: "[drawbacks]")
            } else if line.hasPrefix("[alternatives]") {
                alternatives = extract(line, prefix: "[alternatives]")
            } else if line.hasPrefix("[questions]") {
                questions = extract(line, prefix: "[questions]")
            }
        }

        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let slug = title.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return """
        ---
        title: "\(title)"
        status: draft
        date: \(date)
        slug: \(slug)
        ---

        ## Summary

        \(proposal.isEmpty ? "_Proposal not provided._" : proposal)

        ## Motivation

        \(problem.isEmpty ? "_Problem statement not provided._" : problem)

        ## Detailed Design

        \(design.isEmpty ? "_Design details not provided._" : design)

        ## Drawbacks

        \(drawbacks.isEmpty ? "No significant drawbacks identified at this stage." : drawbacks)

        ## Alternatives

        \(alternatives.isEmpty ? "No alternatives documented." : alternatives)

        ## Adoption Strategy

        This RFC will be reviewed by relevant stakeholders before implementation begins.
        Changes should be rolled out incrementally with feature flags where appropriate.

        ## Unresolved Questions

        \(questions.isEmpty ? "None at this time." : questions)
        """
    }

    private func extract(_ line: String, prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
