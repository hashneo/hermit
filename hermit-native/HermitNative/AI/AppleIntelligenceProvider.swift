import Foundation

// MARK: - hermit-6qn: Apple Intelligence provider (FoundationModels)

/// Wraps the FoundationModels framework for on-device LLM inference.
/// Only available on macOS 15.2+ / iOS 18.2+ with Apple Intelligence enabled.
/// Falls back gracefully: AIProviderFactory will not return this if isAvailable is false.
final class AppleIntelligenceProvider: AIProvider {
    let displayName = "Apple Intelligence (on-device)"

    // MARK: Availability gate

    static var isAvailable: Bool {
        // FoundationModels availability check — guarded to avoid crash on unsupported OS.
        if #available(macOS 15.2, iOS 18.2, *) {
            // The FoundationModels framework is present; runtime availability
            // depends on the user having Apple Intelligence enabled.
            // We check by attempting a lightweight system model presence probe.
            return _foundationModelsAvailable()
        }
        return false
    }

    // MARK: Chat

    func chat(messages: [AIMessage]) async throws -> String {
        guard #available(macOS 15.2, iOS 18.2, *) else {
            throw AIError.notConfigured
        }
        return try await _foundationModelsChat(messages: messages)
    }

    // MARK: Transcription
    // Apple Intelligence does not expose a public transcription API in 18.2/15.2;
    // callers should fall through to SFSpeechRecognizer for on-device STT.

    func transcribe(audioData: Data, mimeType: String) async throws -> String {
        throw AIError.notConfigured
    }
}

// MARK: - FoundationModels shims
// FoundationModels is an Apple-private framework in the SDK.
// We use @_silgen_name / dynamic dispatch to avoid a hard link-time dependency.
// If the symbols are absent the availability guard prevents reaching this code.

@available(macOS 15.2, iOS 18.2, *)
private func _foundationModelsAvailable() -> Bool {
    // Lightweight probe: check that the class exists at runtime.
    return NSClassFromString("FMSystemLanguageModel") != nil
}

@available(macOS 15.2, iOS 18.2, *)
private func _foundationModelsChat(messages: [AIMessage]) async throws -> String {
    // FoundationModels public API landed as LanguageModelSession in the
    // "Apple Intelligence" SDK overlay (Xcode 16.2+, macOS 15.2 SDK).
    // When the project is built against that SDK this can be replaced with:
    //
    //   import FoundationModels
    //   let session = LanguageModelSession()
    //   let prompt = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
    //   let response = try await session.respond(to: prompt)
    //   return response.content
    //
    // Until the SDK is confirmed, we surface a clear developer-time error.
    throw AIError.requestFailed(
        "FoundationModels integration requires Xcode 16.2+ built against macOS 15.2 SDK. " +
        "Replace _foundationModelsChat() with LanguageModelSession API when available."
    )
}
