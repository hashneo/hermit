import Foundation

// MARK: - hermit-wzm: RFCInterviewSession — multi-turn AI interview state machine

@MainActor
final class RFCInterviewSession: ObservableObject {

    struct Message: Identifiable {
        enum Sender { case assistant, user }
        let id = UUID()
        let sender: Sender
        let text: String
    }

    enum SessionState {
        case idle, interviewing, assembling, reviewing, complete, failed(String)
    }

    @Published var messages: [Message] = []
    @Published var state: SessionState = .idle
    @Published var currentStage: RFCInterviewPrompts.Stage = .greeting
    @Published var draftMarkdown: String = ""
    @Published var isLoading = false

    private let aiProvider: any AIProvider
    private var stageAnswers: [(stage: RFCInterviewPrompts.Stage, answer: String)] = []
    private var conversationHistory: [AIMessage] = []

    init(aiProvider: any AIProvider) {
        self.aiProvider = aiProvider
    }

    // MARK: - Start

    func start() async {
        state = .interviewing
        conversationHistory = [
            AIMessage(role: .system, content: RFCInterviewPrompts.systemPrompt)
        ]
        let greeting = RFCInterviewPrompts.question(for: .greeting)
        append(message: Message(sender: .assistant, text: greeting))
        conversationHistory.append(AIMessage(role: .assistant, content: greeting))
        currentStage = .title
    }

    // MARK: - User responds

    func respond(with text: String) async {
        guard case .interviewing = state else { return }
        append(message: Message(sender: .user, text: text))
        conversationHistory.append(AIMessage(role: .user, content: text))
        stageAnswers.append((stage: currentStage, answer: text))

        let nextStage = RFCInterviewPrompts.Stage(rawValue: currentStage.rawValue + 1)
            ?? .complete

        if nextStage == .review {
            await assembleRFC()
        } else if nextStage == .complete {
            state = .complete
        } else {
            isLoading = true
            defer { isLoading = false }
            do {
                // Ask AI to acknowledge + ask next question
                let nextQ = RFCInterviewPrompts.question(for: nextStage)
                let ackPrompt = "Briefly acknowledge the user's answer (1 sentence), then ask: \(nextQ)"
                conversationHistory.append(AIMessage(role: .user, content: ackPrompt))
                let reply = try await aiProvider.chat(messages: conversationHistory)
                conversationHistory.append(AIMessage(role: .assistant, content: reply))
                append(message: Message(sender: .assistant, text: reply))
            } catch {
                append(message: Message(sender: .assistant,
                                        text: "⚠️ \(error.localizedDescription)"))
                state = .failed(error.localizedDescription)
            }
            currentStage = nextStage
        }
    }

    // MARK: - Assemble RFC

    private func assembleRFC() async {
        state = .assembling
        isLoading = true
        defer { isLoading = false }
        do {
            let assemblyPrompt = RFCInterviewPrompts.assemblyPrompt(transcript: stageAnswers)
            let assemblyMessages = [
                AIMessage(role: .system, content: RFCInterviewPrompts.systemPrompt),
                AIMessage(role: .user, content: assemblyPrompt),
            ]
            draftMarkdown = try await aiProvider.chat(messages: assemblyMessages)
            state = .reviewing
            let previewNote = "Here's your RFC draft. Review it below, then publish when ready."
            append(message: Message(sender: .assistant, text: previewNote))
        } catch {
            append(message: Message(sender: .assistant,
                                    text: "⚠️ Failed to assemble RFC: \(error.localizedDescription)"))
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        messages = []
        state = .idle
        currentStage = .greeting
        draftMarkdown = ""
        stageAnswers = []
        conversationHistory = []
        isLoading = false
    }

    private func append(message: Message) {
        messages.append(message)
    }
}
