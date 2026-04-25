---
title: Voice Mode and Hands-Free Conversation
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [voice, stt, tts, avfoundation, speech, hands-free, rfc]
id: rfc-011
project_id: hermit
doc_uuid: a1b2c3d4-0006-4000-8000-100000000011
---

# Summary

This RFC defines the voice mode system for the Hermit native app — a fully hands-free, conversational interface for RFC authoring and inline commenting. The app speaks questions aloud using `AVSpeechSynthesizer`, listens for answers via `AVAudioEngine`, converts speech to text using either on-device `SFSpeechRecognizer` or OpenAI Whisper, and feeds transcriptions back to the AI interview session (rfc-010). Voice mode is available on both macOS and iPadOS.

# Motivation

The RFC interview (rfc-010) and comment compose (rfc-009) flows work well with a keyboard. But the highest-value moments for RFC authoring are often the moments furthest from a keyboard: walking to a meeting, sitting on the couch, standing at a whiteboard. Voice mode makes the full RFC creation and review workflow accessible in those moments.

The hands-free design goes further than "tap to record": the app speaks its questions aloud and listens automatically, creating a genuine back-and-forth conversation. This matches the mental model engineers already have from voice assistants and removes the visual attention required to read questions on screen.

Voice commenting on iPad is equally valuable — an engineer reading an RFC can leave a verbal comment without interrupting their reading posture or reaching for a keyboard.

# Detailed Design

## System Framework Stack

| Concern | Framework | Notes |
|---|---|---|
| Microphone capture | `AVFoundation` / `AVAudioEngine` | Streaming, low-latency |
| On-device STT | `Speech` / `SFSpeechRecognizer` | Free, private, requires user permission |
| Cloud STT | OpenAI Whisper API | Higher accuracy, requires OpenAI key |
| TTS (question readback) | `AVFoundation` / `AVSpeechSynthesizer` | System voices, no external dependency |
| Audio session management | `AVAudioSession` | Handles interruptions, routing, modes |

No third-party libraries are required.

## VoiceEngine

`VoiceEngine.swift` is the central `actor` that owns the audio hardware. It is a singleton, shared across all voice contexts (interview and comment sessions).

```swift
// Voice/VoiceEngine.swift
actor VoiceEngine {
    enum State {
        case idle
        case listening(startedAt: Date)
        case processing
        case speaking
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var waveformAmplitudes: [Float] = []  // for UI waveform
    @Published private(set) var liveTranscript: String = ""       // real-time partial text

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    func startListening() async throws
    func stopListening() async -> String        // returns final transcript
    func speak(_ text: String) async            // blocks until utterance completes
    func cancelSpeech()
}
```

### Audio Session Configuration

```swift
// Called on VoiceEngine init
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord,
                         mode: .voiceChat,
                         options: [.defaultToSpeaker, .allowBluetooth])
try session.setActive(true)
```

`voiceChat` mode enables acoustic echo cancellation — essential so the microphone does not pick up the synthesiser's spoken questions. `.allowBluetooth` enables AirPods and Bluetooth headsets.

### Silence Detection

Continuous recording would produce unbounded audio. The engine uses a rolling RMS amplitude buffer to detect silence:

```swift
// In the AVAudioEngine tap block:
let rms = /* compute RMS of buffer */
amplitudeBuffer.append(rms)
if amplitudeBuffer.count > silenceWindowFrames {
    amplitudeBuffer.removeFirst()
    if amplitudeBuffer.max()! < silenceThreshold {
        // Silence detected — auto-stop listening
        await stopListening()
    }
}
```

Configuration:
- `silenceThreshold`: 0.02 (adjustable in Settings as "Microphone sensitivity")
- `silenceWindowFrames`: frames equivalent to 1.5 seconds of silence
- Maximum listening duration: 120 seconds (safety cutback, configurable)

The waveform amplitude array is published at 30 Hz for the UI visualiser.

## SpeechRecognizer

`SpeechRecognizer.swift` wraps both the on-device and cloud paths behind a unified interface:

```swift
// Voice/SpeechRecognizer.swift
struct SpeechRecognizer {

    enum Backend { case onDevice, whisper }

    static func transcribe(audioURL: URL, backend: Backend, openAIKey: String? = nil) async throws -> String {
        switch backend {
        case .onDevice:
            return try await transcribeOnDevice(audioURL: audioURL)
        case .whisper:
            guard let key = openAIKey else { throw STTError.missingAPIKey }
            return try await transcribeWhisper(audioURL: audioURL, apiKey: key)
        }
    }

    // SFSpeechRecognizer path — streaming, partial results during recording
    private static func transcribeOnDevice(audioURL: URL) async throws -> String { ... }

    // Whisper path — file upload after recording completes
    private static func transcribeWhisper(audioURL: URL, apiKey: String) async throws -> String {
        // POST https://api.openai.com/v1/audio/transcriptions
        // Content-Type: multipart/form-data
        // file: {audioURL contents}, model: "whisper-1", language: "en"
    }
}
```

### Backend Selection

| Condition | STT Backend Used |
|---|---|
| AI provider = Apple Intelligence | `SFSpeechRecognizer` (on-device) |
| AI provider = OpenAI | Whisper API |
| No AI configured (text-only mode) | `SFSpeechRecognizer` (voice still works, AI assist disabled) |
| `SFSpeechRecognizer` unavailable | Whisper if key present; otherwise voice input disabled |

For the on-device path, `SFSpeechRecognizer` streams partial results live during recording — the `liveTranscript` property in `VoiceEngine` updates in real time as the engineer speaks. Whisper does not provide streaming; the transcript appears only after the recording ends.

## SpeechSynthesizer

`SpeechSynthesizer.swift` wraps `AVSpeechSynthesizer` with async/await:

```swift
// Voice/SpeechSynthesizer.swift
actor SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil) async {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let utterance = AVSpeechUtterancestring(string: text)
            utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.52         // slightly faster than default 0.5
            utterance.pitchMultiplier = 1.0
            utterance.postUtteranceDelay = 0.3
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
        continuation = nil
    }

    // AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }
}
```

Voice selection: defaults to the system Siri voice when available (via `AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Samantha")`). Falls back to any `en-US` voice. Configurable in Settings.

## Voice Interview Flow

`RFCInterviewSession` drives the voice loop:

```
┌─────────────────────────────────────────────────────────┐
│                 Voice Interview Loop                    │
│                                                         │
│  [AI generates question text]                           │
│         ↓                                               │
│  SpeechSynthesizer.speak(question)  ← blocks until done │
│         ↓                                               │
│  VoiceEngine.startListening()                           │
│         ↓                                               │
│  [engineer speaks; liveTranscript updates in UI]        │
│         ↓                                               │
│  [silence detected OR engineer taps "Done"]             │
│         ↓                                               │
│  VoiceEngine.stopListening() → transcript               │
│         ↓                                               │
│  SpeechRecognizer.transcribe() → final text             │
│         ↓                                               │
│  session.advance(userInput: transcript)                  │
│         ↓                                               │
│  [AI generates acknowledgement]                         │
│         ↓                                               │
│  SpeechSynthesizer.speak(acknowledgement)               │
│         ↓                                               │
│  VoiceEngine.startListening()  ← listening for confirm  │
│         ↓                                               │
│  [engineer: "yes" / "no" / "actually..." ]              │
│         ↓                                               │
│  If confirmed: advance to next stage                    │
│  If rejected: re-ask question                           │
└─────────────────────────────────────────────────────────┘
```

### Confirmation Detection

Simple keyword matching is used to detect confirmation vs. rejection in the follow-up turn, before calling the AI (fast path):

```swift
func isConfirmation(_ text: String) -> Bool {
    let affirmatives = ["yes", "yeah", "yep", "correct", "right", "exactly", "that's right", "sounds good"]
    let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return affirmatives.contains(where: { lowered.hasPrefix($0) })
}

func isRejection(_ text: String) -> Bool {
    let negatives = ["no", "nope", "not quite", "actually", "wait", "hmm", "that's not"]
    let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return negatives.contains(where: { lowered.hasPrefix($0) })
}
```

If neither pattern matches, the full text is passed to the AI to interpret in context.

## Voice Comment Session

`VoiceCommentSession.swift` is a simplified single-turn flow used from `ComposeCommentView`:

```
AI speaks: "What would you like to comment on this section?"
    ↓
VoiceEngine listens
    ↓
Transcript shown in TextEditor for review/edit
    ↓
AI speaks: "Got it. Ready to submit, or would you like to change anything?"
    ↓
Engineer: "submit" → comment posted
Engineer: "change..." → TextEditor focused, engineer edits manually
```

The voice comment session always falls back to displaying the transcript in the text editor — the engineer has final review before submission.

## Voice UI Components

### Waveform Visualiser

An animated waveform bar chart, driven by `VoiceEngine.waveformAmplitudes`:

```swift
// Views shared component
struct WaveformView: View {
    let amplitudes: [Float]  // 30 samples, updated at 30 Hz

    var body: some View {
        HStack(spacing: 3) {
            ForEach(amplitudes.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .frame(width: 3, height: CGFloat(amplitudes[i]) * 60 + 4)
                    .foregroundStyle(.tint)
                    .animation(.easeInOut(duration: 0.05), value: amplitudes[i])
            }
        }
    }
}
```

### Live Transcript Display

The `liveTranscript` string from `VoiceEngine` is displayed in a scrolling text area below the waveform, updating word by word as the engineer speaks. This gives confidence that the microphone is working and the speech is being captured correctly.

### Interruption Handling

The app observes `AVAudioSession.interruptionNotification` (e.g. incoming phone call, Siri activation). On interruption:
- The synthesiser is stopped immediately.
- If listening, the current recording is abandoned (not transcribed).
- The voice session state resets to the start of the current stage.
- On interruption end (with `shouldResume` hint), the stage question is re-spoken automatically.

## Permissions

### Microphone

`NSMicrophoneUsageDescription` (Info.plist): *"Hermit uses the microphone to let you create RFCs and leave comments using your voice."*

Requested on first use of voice mode. If denied, voice mode buttons are hidden and a Settings deep-link prompt is shown.

### Speech Recognition

`NSSpeechRecognitionUsageDescription` (Info.plist): *"Hermit converts your speech to text for voice-driven RFC authoring and commenting."*

Requested the first time `SFSpeechRecognizer` is activated. If denied, the Whisper cloud path is used instead (if available); otherwise voice mode is disabled.

## macOS-Specific Considerations

On macOS, `AVSpeechSynthesizer` and `AVAudioEngine` are available on macOS 14+. The voice flow works identically to iPadOS. The menu bar popover expands to accommodate the waveform visualiser and live transcript during voice sessions. Engineers using AirPods with their Mac get the full spatial audio + echo cancellation experience.

# Drawbacks

- Microphone access requires a user permission prompt that can feel intrusive for a productivity app. Clear copy in the permission rationale and optional onboarding flow mitigate this.
- On-device `SFSpeechRecognizer` accuracy degrades with technical vocabulary (API names, acronyms, domain jargon). Whisper handles technical content better. Engineers who use many technical terms will get better results with OpenAI configured.
- The silence detection threshold must be tuned carefully. Too sensitive: recording cuts off mid-sentence. Too permissive: recording continues through long pauses. The configurable sensitivity in Settings allows engineers to tune it for their environment.
- `AVSpeechSynthesizer` voices, while significantly improved in recent OS versions, can still feel robotic. Engineers may find the synthesised questions distracting. A "voice mode without readback" option (display questions, listen for answers) should be offered as an alternative.

# Alternatives

## Alternative 1: Push-to-Talk Only

Engineer holds a button to record, releases to submit. Simpler implementation, no silence detection complexity. Loses the fully hands-free experience that makes voice mode valuable in couch/mobile scenarios.

## Alternative 2: Whisper Always (No On-Device STT)

Always use Whisper for transcription, removing the `SFSpeechRecognizer` code path. Simpler but requires an OpenAI key for voice to work at all, and sends audio data to OpenAI. Privacy-sensitive users and those without an OpenAI account cannot use voice. Rejected.

## Alternative 3: System Speech Recognition (Dictation)

Use the macOS/iOS system dictation feature (invoked programmatically via UIKit/AppKit text fields). This requires the UI to be focused on a text field and does not support the custom voice loop. Rejected.

# Adoption Strategy

Voice mode is an opt-in feature activated by the microphone button in the interview and comment compose views. Engineers who prefer typing are not affected. On first use, the app walks through the permission prompts with explanatory copy.

# Unresolved Questions

- Should the TTS voice be customisable (different system voices, speaking rate)? Yes, but deferred to Settings v2.
- Should the app support languages other than English? `SFSpeechRecognizer` supports many locales. The RFC template and AI system prompts are English-only at this stage.
- How should voice mode behave when the device is locked (iPad used as a reading device)? Background audio recording is not permitted while the app is backgrounded. Voice mode requires the app to be in the foreground.

# Future Possibilities

- Streaming AI responses: as the AI generates its acknowledgement text, speak it word by word as it arrives (streaming TTS). Reduces the wait between the engineer's answer and the AI's response.
- Siri Shortcuts integration: "Hey Siri, create a new Hermit RFC" launches the voice interview from the lock screen.
- ElevenLabs or custom voice: organisations can configure a custom TTS voice for the AI interviewer to match their brand.
