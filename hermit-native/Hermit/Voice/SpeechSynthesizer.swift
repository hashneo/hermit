import Foundation
import AVFoundation

// MARK: - hermit-mfe: SpeechSynthesizer

/// Async/await wrapper around AVSpeechSynthesizer for AI question readback.
@MainActor
final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate, ObservableObject {

    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil) async {
        // Cancel any in-flight speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)

        isSpeaking = true
        await withCheckedContinuation { cont in
            continuation = cont
            synthesizer.speak(utterance)
        }
        isSpeaking = false
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}
