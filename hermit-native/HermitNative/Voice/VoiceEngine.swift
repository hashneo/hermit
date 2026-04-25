import Foundation
import AVFoundation

// MARK: - hermit-cmy: VoiceEngine
// hermit-1jz: AVAudioSession interruption handling
// hermit-9fj: Microphone and speech recognition permission handling

/// Captures microphone audio via AVAudioEngine.
/// Streams PCM buffers to a consumer, detects silence, and emits waveform amplitude data.
@MainActor
final class VoiceEngine: NSObject, ObservableObject {

    // MARK: State

    enum State { case idle, requesting, recording, stopping }
    @Published var state: State = .idle
    @Published var amplitude: Float = 0        // 0–1, for WaveformView
    @Published var permissionDenied = false

    // MARK: Configuration

    struct Config {
        var silenceThreshold: Float = 0.01     // RMS below this → silence
        var silenceDuration: TimeInterval = 1.5 // seconds of silence before auto-stop
        var sampleRate: Double = 16_000        // Hz — Whisper prefers 16 kHz
    }
    var config = Config()

    // MARK: Callbacks

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSilenceDetected: (() -> Void)?

    // MARK: Private

    private var engine = AVAudioEngine()
    private var silenceTimer: Timer?
    private var recordingTask: Task<Void, Never>?

    // MARK: - Permissions (hermit-9fj)

    func requestPermission() async -> Bool {
        state = .requesting
        let granted: Bool
#if os(macOS)
        granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
#else
        granted = await AVAudioApplication.requestRecordPermission()
#endif
        if !granted { permissionDenied = true; state = .idle }
        return granted
    }

    // MARK: - Recording

    func startRecording() async throws {
        guard await requestPermission() else { return }
        setupInterruptionObserver()

#if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setPreferredSampleRate(config.sampleRate)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.procesBuffer(buffer)
            }
        }

        try engine.start()
        state = .recording
        resetSilenceTimer()
    }

    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
#if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false,
              options: .notifyOthersOnDeactivation)
#endif
        state = .idle
        amplitude = 0
    }

    // MARK: - Private

    private func procesBuffer(_ buffer: AVAudioPCMBuffer) {
        onAudioBuffer?(buffer)
        let rms = Self.rms(buffer)
        amplitude = min(rms * 10, 1.0) // scale for visual
        if rms < config.silenceThreshold {
            // extend or start silence timer
        } else {
            resetSilenceTimer()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: config.silenceDuration,
                                            repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onSilenceDetected?()
            }
        }
    }

    // MARK: - Interruption handling (hermit-1jz)

    private var interruptionObserver: NSObjectProtocol?

    private func setupInterruptionObserver() {
#if !os(macOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            Task { @MainActor [weak self] in
                switch type {
                case .began:
                    self?.stopRecording()
                case .ended:
                    break  // User manually restarts
                @unknown default:
                    break
                }
            }
        }
#endif
    }

    // MARK: - RMS helper

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        let channel = data[0]
        for i in 0..<count { sum += channel[i] * channel[i] }
        return sqrt(sum / Float(count))
    }
}
