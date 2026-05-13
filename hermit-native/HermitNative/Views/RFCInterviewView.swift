import SwiftUI

// MARK: - hermit-c7r: RFCInterviewView

struct RFCInterviewView: View {
    @StateObject private var session: RFCInterviewSession
    @StateObject private var synthesizer = SpeechSynthesizer()
    @StateObject private var voice = LiveVoiceSession()
    @State private var inputText = ""
    @State private var useVoice = false
    @State private var showPreview = false

    @EnvironmentObject private var appState: AppState

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
                        // In voice mode: speak the AI question, then auto-start listening
                        if useVoice, last.sender == .assistant {
                            Task {
                                await synthesizer.speak(last.text)
                                // After speaking, immediately start listening for the answer
                                guard useVoice, voice.state == .idle else { return }
                                if case .reviewing = session.state { return }
                                if case .complete  = session.state { return }
                                voice.startListening()
                            }
                        }
                    }
                }
            }

            Divider()

            // Bottom input area
            if case .reviewing = session.state {
                Button("Preview & Publish →") { showPreview = true }
                    .buttonStyle(.borderedProminent)
                    .padding()
            } else if case .complete = session.state {
                Text("Done! Check Hermit for your RFC.").foregroundStyle(.secondary).padding()
            } else if useVoice {
                voiceInputRow
            } else {
                textInputRow
            }
        }
        .navigationTitle("New RFC")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $useVoice) {
                    Label(useVoice ? "Voice" : "Type", systemImage: useVoice ? "mic.fill" : "keyboard")
                }
                .toggleStyle(.button)
                .onChange(of: useVoice) { _, nowVoice in
                    if !nowVoice {
                        // Switched to keyboard — stop listening
                        synthesizer.stop()
                        voice.stopListening(submit: false)
                    } else {
                        // Switched to voice — if AI already asked something, start listening
                        if !session.isLoading && !session.messages.isEmpty,
                           let last = session.messages.last, last.sender == .assistant {
                            Task {
                                await synthesizer.speak(last.text)
                                voice.startListening()
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showPreview) {
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
        // Wire voice transcription → send answer
        .onAppear {
            voice.onTranscription = { text in
                Task {
                    await session.respond(with: text)
                    voice.markProcessingDone()
                    // Next listen cycle triggered by .onChange(of: session.messages)
                }
            }
        }
    }

    // MARK: - Voice input row (organic — shows live transcript + amplitude)

    private var voiceInputRow: some View {
        VStack(spacing: 6) {
            // Live transcript
            Group {
                switch voice.state {
                case .idle:
                    Text("Tap mic or wait — listening starts automatically")
                        .foregroundStyle(.tertiary)
                case .listening:
                    Text(voice.liveText.isEmpty ? "Listening…" : voice.liveText)
                        .foregroundStyle(voice.liveText.isEmpty ? .tertiary : .primary)
                case .processing:
                    Text("Got it…")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.2), value: voice.liveText)

            HStack(spacing: 16) {
                // Waveform
                WaveformView(amplitude: voice.amplitude)
                    .frame(maxWidth: .infinity)

                // Mic button — tap to force-start or force-stop
                Button {
                    switch voice.state {
                    case .idle:
                        voice.startListening()
                    case .listening:
                        voice.stopListening(submit: true)
                    case .processing:
                        break
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(voice.state == .listening ? Color.red : Color.accentColor)
                            .frame(width: 44, height: 44)
                        Image(systemName: voice.state == .processing ? "ellipsis" : "mic.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(voice.state == .processing || session.isLoading)
                // Pulse animation when listening
                .scaleEffect(voice.state == .listening ? 1.0 : 0.92)
                .animation(
                    voice.state == .listening
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: voice.state == .listening
                )
            }
            .padding(.horizontal)

            // Status hint
            Group {
                switch voice.state {
                case .listening:
                    Text("Pause and I'll send automatically · Tap mic to send now")
                case .processing:
                    Text("Thinking…")
                case .idle:
                    Text("Tap mic to speak")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Text input row

    private var textInputRow: some View {
        HStack(spacing: 8) {
            TextField("Your answer…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await sendText() } }
            Button {
                Task { await sendText() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || session.isLoading)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func sendText() async {
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
