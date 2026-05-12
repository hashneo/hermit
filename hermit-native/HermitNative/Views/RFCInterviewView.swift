import SwiftUI

// MARK: - hermit-c7r: RFCInterviewView — chat-bubble UI with progress bar and voice toggle
// hermit-7nx: Voice interview loop

struct RFCInterviewView: View {
    @StateObject private var session: RFCInterviewSession
    @StateObject private var voiceEngine = VoiceEngine()
    @StateObject private var synthesizer = SpeechSynthesizer()
    // hermit-il8: single SpeechRecognizer instance owned here, passed into VoiceInterviewInputRow
    @StateObject private var speechRecognizer: SpeechRecognizerBox
    @State private var inputText = ""
    @State private var useVoice = false
    @State private var showPreview = false

    // hermit-zbp: client context pulled from environment for downstream injection
    @EnvironmentObject private var appState: AppState

    init(aiProvider: any AIProvider) {
        _session = StateObject(wrappedValue: RFCInterviewSession(aiProvider: aiProvider))
        _speechRecognizer = StateObject(wrappedValue: SpeechRecognizerBox(aiProvider: aiProvider))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            let stages = RFCInterviewPrompts.Stage.allCases
            let progress = Double(session.currentStage.rawValue) / Double(stages.count - 1)
            ProgressView(value: progress)
                .tint(.accentColor)
                .padding(.horizontal)
                .padding(.vertical, 6)

            Divider()

            // Chat bubbles
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if session.isLoading {
                            HStack { ProgressView().controlSize(.small); Spacer() }
                                .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        // hermit-7nx: speak assistant messages in voice mode
                        if useVoice, last.sender == .assistant {
                            Task { await synthesizer.speak(last.text) }
                        }
                    }
                }
            }

            Divider()

            // Review/publish transition
            if case .reviewing = session.state {
                Button("Preview & Publish →") { showPreview = true }
                    .buttonStyle(.borderedProminent)
                    .padding()
            } else if case .complete = session.state {
                Text("Done! Check Hermit for your RFC.").foregroundStyle(.secondary).padding()
            } else {
                // Input row
                inputRow
            }
        }
        .navigationTitle("New RFC")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $useVoice) {
                    Image(systemName: "keyboard").tag(false)
                    Image(systemName: "mic").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
            }
        }
        .sheet(isPresented: $showPreview) {
            // hermit-zbp: inject client/docsPath/rfcLabel from AppState environment
            if let client = appState.makeAPIClient() {
                RFCPreviewView(
                    markdown: session.draftMarkdown,
                    client: client,
                    docsPath: appState.docsPath,
                    rfcLabel: appState.rfcLabel,
                    onPublish: { showPreview = false }
                )
            } else {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Configure a repository in Settings before publishing.")
                )
            }
        }
        .task {
            if case .idle = session.state { await session.start() }
        }
    }

    // MARK: - Input row

    @ViewBuilder
    private var inputRow: some View {
        if useVoice {
            // hermit-il8: pass speechRecognizer into VoiceInterviewInputRow
            VoiceInterviewInputRow(
                voiceEngine: voiceEngine,
                speechRecognizer: speechRecognizer.recognizer,
                onTranscription: { text in
                    inputText = text
                    Task { await sendInput() }
                }
            )
        } else {
            HStack(spacing: 8) {
                TextField("Your answer…", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await sendInput() } }
                Button {
                    Task { await sendInput() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || session.isLoading)
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }

    private func sendInput() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        await session.respond(with: text)
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: RFCInterviewSession.Message

    var isAssistant: Bool { message.sender == .assistant }

    var body: some View {
        HStack {
            if !isAssistant { Spacer(minLength: 40) }
            Text(message.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isAssistant ? Color.secondary.opacity(0.15) : Color.accentColor)
                .foregroundStyle(isAssistant ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if isAssistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - hermit-il8: SpeechRecognizerBox — ObservableObject wrapper so RFCInterviewView can hold actor as @StateObject

@MainActor
final class SpeechRecognizerBox: ObservableObject {
    let recognizer: SpeechRecognizer
    init(aiProvider: any AIProvider) {
        recognizer = SpeechRecognizer(aiProvider: aiProvider)
    }
}

// MARK: - hermit-7nx: Voice interview input row

private struct VoiceInterviewInputRow: View {
    @ObservedObject var voiceEngine: VoiceEngine
    let speechRecognizer: SpeechRecognizer  // hermit-il8: injected from RFCInterviewView
    var onTranscription: (String) -> Void

    @State private var liveText = ""
    @State private var transcriptionTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 8) {
            WaveformView(amplitude: voiceEngine.amplitude)
            HStack {
                Text(liveText.isEmpty ? "Tap to speak…" : liveText)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if voiceEngine.state == .recording {
                    Button("Done") {
                        finishRecording()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        startRecording()
                    } label: {
                        Image(systemName: "mic.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain).tint(.accentColor)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .onDisappear {
            transcriptionTask?.cancel()
        }
    }

    // hermit-il8: start VoiceEngine + SFSpeechRecognizer live transcription together
    private func startRecording() {
        liveText = ""
        transcriptionTask = Task {
            do {
                // Start SFSpeechRecognizer live transcription — gets (request, stream)
                let (request, stream) = try await speechRecognizer.startLiveTranscription()

                // Wire VoiceEngine audio buffers into the recognition request
                voiceEngine.onAudioBuffer = { buffer in
                    request.append(buffer)
                }

                // Auto-stop on silence
                voiceEngine.onSilenceDetected = {
                    finishRecording()
                }

                try await voiceEngine.startRecording()

                // Consume transcription stream, updating liveText in real time
                for await partial in stream {
                    if Task.isCancelled { break }
                    await MainActor.run { liveText = partial }
                }
            } catch {
                // Permission denied or unavailable — surface in liveText
                await MainActor.run { liveText = error.localizedDescription }
            }
        }
    }

    private func finishRecording() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        voiceEngine.onAudioBuffer = nil
        voiceEngine.onSilenceDetected = nil
        voiceEngine.stopRecording()
        let final = liveText
        liveText = ""
        if !final.isEmpty { onTranscription(final) }
    }
}
