import Foundation
// hermit-ijn: FoundationModels ships in macOS 26+ / iOS 26+ (Xcode 26 SDK).
// The conditional import keeps older toolchains compiling; #available guards
// prevent execution on unsupported OS versions at runtime.
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - hermit-6qn: Apple Intelligence provider (FoundationModels)

/// Wraps the FoundationModels framework for on-device LLM inference.
/// Only available on macOS 26+ / iOS 26+ with Apple Intelligence enabled.
/// Falls back gracefully: AIProviderFactory will not return this if isAvailable is false.
final class AppleIntelligenceProvider: AIProvider {
    let displayName = "Apple Intelligence (on-device)"

    // MARK: Availability gate

    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return _foundationModelsAvailable()
        }
        return false
    }

    // MARK: Chat

    func chat(messages: [AIMessage]) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AIError.notConfigured
        }
        return try await _foundationModelsChat(messages: messages)
    }

    // MARK: Transcription
    // Apple Intelligence does not expose a public transcription API;
    // callers should fall through to SFSpeechRecognizer for on-device STT.

    func transcribe(audioData: Data, mimeType: String) async throws -> String {
        throw AIError.notConfigured
    }
}

// MARK: - FoundationModels implementation (hermit-ijn)

@available(macOS 26.0, iOS 26.0, *)
private func _foundationModelsAvailable() -> Bool {
    // Lightweight probe: check that the class exists at runtime.
    return NSClassFromString("FMSystemLanguageModel") != nil
}

// hermit-ijn: real LanguageModelSession implementation.
// LanguageModelSession is single-turn; we build one formatted prompt from the
// [AIMessage] array: system message first, alternating user/assistant, ending on user.
@available(macOS 26.0, iOS 26.0, *)
private func _foundationModelsChat(messages: [AIMessage]) async throws -> String {
#if canImport(FoundationModels)
    var parts: [String] = []
    for msg in messages {
        switch msg.role {
        case .system:
            parts.append("[System]\n\(msg.content)")
        case .user:
            parts.append("[User]\n\(msg.content)")
        case .assistant:
            parts.append("[Assistant]\n\(msg.content)")
        }
    }
    let prompt = parts.joined(separator: "\n\n")

    // FoundationModels public API — available macOS 26+ / iOS 26+
    let session = LanguageModelSession()
    let response = try await session.respond(to: prompt)
    return response.content
#else
    throw AIError.requestFailed(
        "FoundationModels requires the macOS 26 SDK (Xcode 26+)."
    )
#endif
}
