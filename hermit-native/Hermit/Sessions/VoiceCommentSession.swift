import Foundation
import AVFoundation

// MARK: - hermit-9t9: VoiceCommentSession — single-turn voice capture + confirmation

@MainActor
final class VoiceCommentSession: ObservableObject {

    enum State {
        case idle, recording, transcribing, confirming(String), submitting, done, failed(String)
    }

    @Published var state: State = .idle
    @Published var amplitude: Float = 0

    private let voiceEngine: VoiceEngine
    private let speechRecognizer: SpeechRecognizer
    private var audioBuffers: [AVAudioPCMBuffer] = []

    init(voiceEngine: VoiceEngine, speechRecognizer: SpeechRecognizer) {
        self.voiceEngine = voiceEngine
        self.speechRecognizer = speechRecognizer
    }

    // MARK: - Record

    func startRecording() async {
        audioBuffers = []
        voiceEngine.onAudioBuffer = { [weak self] buffer in
            Task { @MainActor [weak self] in
                self?.audioBuffers.append(buffer)
            }
        }
        voiceEngine.onSilenceDetected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.stopAndTranscribe()
            }
        }
        do {
            try await voiceEngine.startRecording()
            state = .recording
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopAndTranscribe() async {
        voiceEngine.stopRecording()
        state = .transcribing

        do {
            let audioData = packBuffersToData(audioBuffers)
            let text = try await speechRecognizer.transcribe(
                audioData: audioData, mimeType: "audio/wav", path: .onDevice)
            state = .confirming(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func confirm() { }   // caller transitions to submission
    func cancel() { state = .idle; audioBuffers = [] }
    func reset() { state = .idle; audioBuffers = []; amplitude = 0 }

    // MARK: - Pack PCM buffers → raw WAV Data (simplified, no header)
    // Full WAV header writing is done in the Whisper path; on-device SFSpeechRecognizer
    // accepts .caf which AVAudioEngine captures natively.
    private func packBuffersToData(_ buffers: [AVAudioPCMBuffer]) -> Data {
        var data = Data()
        for buf in buffers {
            guard let channel = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            let bytes = UnsafeBufferPointer(start: channel[0], count: count)
            data.append(contentsOf: bytes.flatMap { withUnsafeBytes(of: $0, Array.init) })
        }
        return data
    }
}
