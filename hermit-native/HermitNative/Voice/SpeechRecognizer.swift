import Foundation
import Speech
import AVFoundation

// MARK: - hermit-rmy: SpeechRecognizer

/// Transcribes audio via SFSpeechRecognizer (on-device) or Whisper (OpenAI cloud).
/// Falls back to Whisper when on-device recognition is unavailable.
actor SpeechRecognizer {

    enum Path { case onDevice, whisper }

    private let aiProvider: any AIProvider

    init(aiProvider: any AIProvider) {
        self.aiProvider = aiProvider
    }

    // MARK: - Live transcription (on-device, streaming)

    /// Starts a live recognition task against the audio engine's input node.
    /// Returns an AsyncStream of partial transcriptions.
    func startLiveTranscription(locale: Locale = .current) async throws
        -> (task: SFSpeechAudioBufferRecognitionRequest, stream: AsyncStream<String>) {

        // hermit-67g: request permission first, then check status — prevents premature denial
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            try await requestSpeechPermission()
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else { throw RecognitionError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // hermit-67g: force on-device STT

        let stream = AsyncStream<String> { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal { continuation.finish() }
                } else if let error {
                    continuation.finish()
                    _ = error  // caller observes via stream completion
                }
            }
        }

        return (request, stream)
    }

    // MARK: - Batch transcription (recorded audio → text)

    func transcribe(audioData: Data, mimeType: String, path: Path = .onDevice) async throws -> String {
        switch path {
        case .onDevice:
            return try await onDeviceTranscribe(audioData: audioData)
        case .whisper:
            return try await aiProvider.transcribe(audioData: audioData, mimeType: mimeType)
        }
    }

    // MARK: - Permission request

    private func requestSpeechPermission() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SFSpeechRecognizer.requestAuthorization { status in
                if status == .authorized { cont.resume() }
                else { cont.resume(throwing: RecognitionError.permissionDenied) }
            }
        }
    }

    // MARK: - On-device batch transcription

    private func onDeviceTranscribe(audioData: Data) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable
        else { throw RecognitionError.unavailable }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")
        try audioData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.requiresOnDeviceRecognition = false

        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: RecognitionError.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Errors

    enum RecognitionError: LocalizedError {
        case unavailable
        case permissionDenied
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:          return "Speech recognition is not available."
            case .permissionDenied:     return "Speech recognition permission was denied."
            case .recognitionFailed(let m): return "Recognition failed: \(m)"
            }
        }
    }
}
