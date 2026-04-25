import Foundation

// MARK: - hermit-02g: AIProvider protocol + AIProviderFactory

/// A message in a multi-turn AI conversation.
struct AIMessage {
    enum Role { case system, user, assistant }
    let role: Role
    let content: String
}

/// Abstraction over AI backends (Apple Intelligence, OpenAI).
protocol AIProvider: AnyObject {
    /// Send a multi-turn conversation and return the assistant reply.
    func chat(messages: [AIMessage]) async throws -> String

    /// Transcribe audio data (PCM or m4a) to text.
    func transcribe(audioData: Data, mimeType: String) async throws -> String

    /// Human-readable name for UI display.
    var displayName: String { get }
}

// MARK: - Factory

/// Returns the configured AI provider, falling back gracefully.
/// - If "openai" is configured and a key is present → OpenAIProvider
/// - If "apple" or unset → AppleIntelligenceProvider (falls back to OpenAI if unavailable)
/// - If nothing available → NullAIProvider (errors with user-friendly message)
enum AIProviderFactory {

    static func makeProvider() -> any AIProvider {
        let keychain = KeychainHelper.shared
        let pref = keychain.aiProvider ?? "apple"

        if pref == "openai", let key = keychain.openAIKey, !key.isEmpty {
            return OpenAIProvider(apiKey: key)
        }

        if AppleIntelligenceProvider.isAvailable {
            return AppleIntelligenceProvider()
        }

        // Graceful fallback: try OpenAI even if not explicitly preferred
        if let key = keychain.openAIKey, !key.isEmpty {
            return OpenAIProvider(apiKey: key)
        }

        return NullAIProvider()
    }
}

// MARK: - Null provider (graceful degradation)

final class NullAIProvider: AIProvider {
    let displayName = "AI Unavailable"

    func chat(messages: [AIMessage]) async throws -> String {
        throw AIError.notConfigured
    }

    func transcribe(audioData: Data, mimeType: String) async throws -> String {
        throw AIError.notConfigured
    }
}

// MARK: - AI errors

enum AIError: LocalizedError {
    case notConfigured
    case requestFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI provider configured. Add an OpenAI key in Settings → AI, or enable Apple Intelligence."
        case .requestFailed(let msg):
            return "AI request failed: \(msg)"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}
