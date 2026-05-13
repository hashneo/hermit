import Foundation
import Speech
import AVFoundation

// MARK: - LiveVoiceSession
// Unified @MainActor class that owns AVAudioEngine + SFSpeechRecognizer for
// the voice interview loop. Replaces the split VoiceEngine/SpeechRecognizer actor
// approach which had actor-boundary ordering issues.

@MainActor
final class LiveVoiceSession: ObservableObject {

    enum State {
        case idle           // not recording
        case listening      // mic open, transcribing
        case processing     // submitted, waiting for AI
    }

    @Published var state: State = .idle
    @Published var liveText: String = ""
    @Published var amplitude: Float = 0     // 0–1 for waveform

    // Called when silence detected and we have text — caller submits it
    var onTranscription: ((String) -> Void)?

    // MARK: - Private

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    private var silenceTimer: Timer?
    private let silenceDuration: TimeInterval = 1.8   // seconds quiet → auto-submit
    private let silenceThreshold: Float       = 0.012 // RMS below this = silence

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        // Microphone
        let micGranted: Bool
        #if os(macOS)
        micGranted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        #else
        micGranted = await AVAudioApplication.requestRecordPermission()
        #endif
        guard micGranted else { return false }

        // Speech recognition
        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        return speechGranted
    }

    // MARK: - Start / Stop

    func startListening() {
        guard state == .idle else { return }
        Task { await _start() }
    }

    func stopListening(submit: Bool = false) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        amplitude = 0

        let captured = liveText
        if submit && !captured.trimmingCharacters(in: .whitespaces).isEmpty {
            state = .processing
            liveText = ""
            onTranscription?(captured)
        } else {
            state = .idle
            if !submit { liveText = "" }
        }
    }

    func markProcessingDone() {
        state = .idle
    }

    // MARK: - Private implementation

    private func _start() async {
        liveText = ""
        amplitude = 0

        // Permissions
        let ok = await requestPermissions()
        guard ok else {
            liveText = "Microphone or speech access denied — check System Settings."
            return
        }

        // Build recognizer — allow network fallback if on-device not available
        let rec = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec, rec.isAvailable else {
            liveText = "Speech recognition unavailable."
            return
        }
        recognizer = rec

        // Reset engine
        audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Allow network fallback — on-device only silently fails on many Macs
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                // Amplitude for waveform
                let rms = Self.rms(buffer)
                self.amplitude = min(rms * 12, 1.0)
                // Silence detection
                if rms < self.silenceThreshold {
                    self.armSilenceTimer()
                } else {
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                }
            }
        }

        // Start recognition task
        recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                }
                if let error {
                    // Ignore cancellation errors (normal stop)
                    let ns = error as NSError
                    if ns.domain != "kAFAssistantErrorDomain" || ns.code != 216 {
                        if self.liveText.isEmpty {
                            self.liveText = "Recognition error: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        // Start audio engine
        do {
            try audioEngine.start()
            state = .listening
        } catch {
            liveText = "Audio engine failed: \(error.localizedDescription)"
            recognitionTask?.cancel()
            recognitionTask = nil
        }
    }

    private func armSilenceTimer() {
        guard silenceTimer == nil, state == .listening else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening else { return }
                // Only auto-submit if we actually got something
                let hasText = !self.liveText.trimmingCharacters(in: .whitespaces).isEmpty
                self.stopListening(submit: hasText)
            }
        }
    }

    // MARK: - RMS helper

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<count { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(count))
    }
}
