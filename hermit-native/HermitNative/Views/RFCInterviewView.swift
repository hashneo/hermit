import SwiftUI

// MARK: - hermit-c7r: RFCInterviewView — chat-bubble UI with progress bar and voice toggle
// hermit-7nx: Voice interview loop

struct RFCInterviewView: View {
    @StateObject private var session: RFCInterviewSession
    @StateObject private var voiceEngine = VoiceEngine()
    @StateObject private var synthesizer = SpeechSynthesizer()
    @State private var inputText = ""
    @State private var useVoice = false
    @State private var showPreview = false

    init(aiProvider: any AIProvider) {
        _session = StateObject(wrappedValue: RFCInterviewSession(aiProvider: aiProvider))
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
            RFCPreviewView(
                markdown: session.draftMarkdown,
                onPublish: { showPreview = false }
            )
        }
        .task {
            if case .idle = session.state { await session.start() }
        }
    }

    // MARK: - Input row

    @ViewBuilder
    private var inputRow: some View {
        if useVoice {
            // hermit-7nx: voice loop — record → transcribe → fill → send
            VoiceInterviewInputRow(
                voiceEngine: voiceEngine,
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

// MARK: - hermit-7nx: Voice interview input row

private struct VoiceInterviewInputRow: View {
    @ObservedObject var voiceEngine: VoiceEngine
    var onTranscription: (String) -> Void

    @StateObject private var recognizer_store = VoiceEngine()  // reuse engine ref
    @State private var liveText = ""

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
                        voiceEngine.stopRecording()
                        onTranscription(liveText)
                        liveText = ""
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { try? await voiceEngine.startRecording() }
                    } label: {
                        Image(systemName: "mic.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain).tint(.accentColor)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}
