import Foundation

// MARK: - hermit-cqu: RFC interview prompts

/// System prompt and per-stage question templates for the AI RFC authoring interview.
enum RFCInterviewPrompts {

    // MARK: System prompt

    static let systemPrompt = """
    You are a technical writing assistant helping a HashiCorp engineer draft an RFC \
    (Request for Comments) document. RFCs follow a standard structure: Summary, Motivation, \
    Detailed Design, Drawbacks, Alternatives, Adoption Strategy, and Unresolved Questions.

    Your job is to interview the engineer stage-by-stage, asking focused questions and \
    synthesising their answers into a well-structured RFC markdown document.

    Guidelines:
    - Ask one focused question at a time.
    - Acknowledge the engineer's answer briefly before moving to the next question.
    - When all stages are complete, produce a complete RFC in markdown with YAML frontmatter.
    - Use clear, direct technical writing. Avoid filler phrases.
    - The RFC title must begin with a concise verb phrase (e.g. "Add", "Replace", "Remove").
    """

    // MARK: Stage definitions

    enum Stage: Int, CaseIterable {
        case greeting
        case title
        case problem
        case proposal
        case designDetails
        case drawbacks
        case alternatives
        case questions
        case review
        case complete
    }

    static func question(for stage: Stage, priorContext: String = "") -> String {
        switch stage {
        case .greeting:
            return "Hi! I'll help you write an RFC. What are you trying to change or add?"
        case .title:
            return "Good. What would be a concise title for this RFC? (e.g. \"Add X\" or \"Replace Y with Z\")"
        case .problem:
            return "What problem does this solve? Why is the current situation unsatisfactory?"
        case .proposal:
            return "What's your proposed solution in a few sentences?"
        case .designDetails:
            return "Walk me through the key design decisions. What are the main components or steps?"
        case .drawbacks:
            return "Are there any drawbacks or risks to this approach?"
        case .alternatives:
            return "What alternatives did you consider, and why did you rule them out?"
        case .questions:
            return "Any unresolved questions or things you're uncertain about?"
        case .review:
            return "Here's a draft based on our conversation. Does it look right, or would you like to adjust anything?"
        case .complete:
            return "Your RFC is ready to publish. Tap 'Publish as PR' to create it on GitHub."
        }
    }

    // MARK: Final assembly prompt

    static func assemblyPrompt(transcript: [(stage: Stage, answer: String)]) -> String {
        let qa = transcript.map { "[\($0.stage)] \($0.answer)" }.joined(separator: "\n")
        return """
        Based on the following interview transcript, produce a complete RFC markdown document \
        with YAML frontmatter. Include all standard sections: Summary, Motivation, Detailed Design, \
        Drawbacks, Alternatives, Adoption Strategy, Unresolved Questions.

        Transcript:
        \(qa)

        Output only the markdown document, starting with the YAML frontmatter block (---).
        """
    }
}
