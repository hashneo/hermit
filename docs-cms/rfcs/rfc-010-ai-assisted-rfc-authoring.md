---
title: AI-Assisted RFC Authoring with Conversational Interview
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [ai, conversational, foundationmodels, interview, openai, rfc, rfc-authoring,
  swift]
id: rfc-010
project_id: hermit
doc_uuid: a1b2c3d4-0005-4000-8000-100000000010
---

# Summary

This RFC defines the AI-assisted RFC authoring system in the Hermit native app. Engineers can create new RFCs through a structured conversational interview conducted by an AI — either by typing or using hands-free voice (rfc-011). The AI asks targeted questions for each section of the RFC template, acknowledges answers with a follow-up turn, then assembles the final markdown document for the engineer to review before publishing to GitHub as a PR (rfc-012).

# Motivation

Starting an RFC from a blank template is a high-friction task. Engineers must recall the template structure, decide how much detail to include, write formal prose for an informal idea, and do all of this while already context-switched away from their primary work.

A conversational interview lowers the activation energy dramatically. The engineer answers natural-language questions; the AI handles structure, formatting, and prose quality. The result is a well-formed RFC draft in minutes, not hours. This directly increases the frequency of RFC submission — and better RFC coverage leads to better engineering decisions.

The conversational format also serves as a thinking aid: being asked "what alternatives did you consider?" forces the engineer to articulate trade-offs they might otherwise skip.

# Detailed Design

## AI Provider Abstraction

```swift
// AI/AIProvider.swift
protocol AIProvider {
    var isAvailable: Bool { get }
    func chat(messages: [ChatMessage]) async throws -> String
    func transcribe(audioURL: URL) async throws -> String
}

struct ChatMessage {
    enum Role { case system, assistant, user }
    let role: Role
    let content: String
}
```

Two concrete providers:

### AppleIntelligenceProvider

Uses the `FoundationModels` framework (macOS 15.2+ / iOS 18.2+). All inference runs on-device — no data leaves the device.

```swift
// AI/AppleIntelligenceProvider.swift
import FoundationModels

struct AppleIntelligenceProvider: AIProvider {
    private let session = LanguageModelSession()

    var isAvailable: Bool {
        LanguageModelSession.isAvailable
    }

    func chat(messages: [ChatMessage]) async throws -> String {
        let prompt = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func transcribe(audioURL: URL) async throws -> String {
        // Delegates to SpeechRecognizer (SFSpeechRecognizer on-device)
        // FoundationModels does not expose STT; transcription is handled separately
        throw AIProviderError.notSupported("Use SpeechRecognizer for transcription")
    }
}
```

### OpenAIProvider

Uses OpenAI's Chat Completions API (`gpt-4o` or `gpt-4o-mini`) and Whisper API for transcription. Requires an API key stored in Keychain.

```swift
// AI/OpenAIProvider.swift
struct OpenAIProvider: AIProvider {
    private let apiKey: String
    private let model: String  // "gpt-4o" | "gpt-4o-mini"

    var isAvailable: Bool { !apiKey.isEmpty }

    func chat(messages: [ChatMessage]) async throws -> String {
        // POST https://api.openai.com/v1/chat/completions
        // body: { model, messages: [{role, content}] }
        // Returns choices[0].message.content
    }

    func transcribe(audioURL: URL) async throws -> String {
        // POST https://api.openai.com/v1/audio/transcriptions
        // multipart/form-data: file={audioURL}, model="whisper-1"
        // Returns text field
    }
}
```

### Provider Selection

```swift
// AI/AIProviderFactory.swift
struct AIProviderFactory {
    static func resolve() -> AIProvider {
        let preference = KeychainHelper.load(key: "hermit.ai.provider") ?? "apple"
        switch preference {
        case "openai":
            if let key = KeychainHelper.load(key: "hermit.openai.key"), !key.isEmpty {
                return OpenAIProvider(apiKey: key, model: "gpt-4o")
            }
            fallthrough
        default:
            if AppleIntelligenceProvider().isAvailable {
                return AppleIntelligenceProvider()
            }
            return NullAIProvider()  // text-only mode, no AI assist
        }
    }
}
```

## RFC Interview Session

`RFCInterviewSession` is an `ObservableObject` that drives the full RFC creation flow as a state machine.

### Interview Stages

```swift
// Sessions/RFCInterviewSession.swift
enum InterviewStage: CaseIterable {
    case greeting
    case title
    case motivation
    case detailedDesign
    case drawbacks
    case alternatives
    case adoptionStrategy
    case unresolvedQuestions
    case confirmation
    case generating
    case review
    case publishing
}
```

### Per-Stage Behaviour

Each stage (except `generating`, `review`, `publishing`) follows the same pattern:

1. **AI asks the question** (from `RFCInterviewPrompts.swift`)
2. **User answers** (text or voice — see rfc-011)
3. **AI acknowledges + rephrases**: one follow-up turn to confirm understanding
   - *"Got it — you want to solve X by doing Y. Is that right?"*
4. If the user says "no" or "not quite", the AI asks the question again with clarification.
5. The confirmed answer is stored in `InterviewAnswers`.
6. Stage advances.

```swift
class RFCInterviewSession: ObservableObject {
    @Published var stage: InterviewStage = .greeting
    @Published var messages: [InterviewMessage] = []
    @Published var isListening: Bool = false
    @Published var isThinking: Bool = false

    private var answers = InterviewAnswers()
    private let provider: AIProvider

    func advance(userInput: String) async {
        // Append user message
        // Call provider.chat() with full message history
        // Parse AI response: is it a confirmation question or a stage-advance trigger?
        // If stage complete: move to next stage, ask next question
    }

    func generateDraft() async throws -> String {
        // Call provider.chat() with assembled answers + RFC template as system context
        // Returns complete RFC markdown string
    }
}

struct InterviewAnswers {
    var title: String = ""
    var motivation: String = ""
    var detailedDesign: String = ""
    var drawbacks: String = ""
    var alternatives: String = ""
    var adoptionStrategy: String = ""
    var unresolvedQuestions: String = ""
}

struct InterviewMessage: Identifiable {
    enum Speaker { case ai, user }
    let id = UUID()
    let speaker: Speaker
    let text: String
    let timestamp: Date
}
```

### System Prompt

The system prompt is loaded from `RFCInterviewPrompts.swift` and is configurable in Settings (advanced). The default prompt:

```text
You are an expert technical writer helping an engineer write a structured RFC
(Request for Comments) document for an engineering organisation.

Your role is to conduct a structured interview, asking one focused question at
a time for each section of the RFC template. After each answer, briefly
acknowledge what you heard in one sentence and ask if you understood correctly.
Only move to the next section after the engineer confirms.

Keep your questions concise and conversational. Use the engineer's own
terminology. Do not explain RFC concepts unless asked.

The RFC sections you must cover in order are:
1. Title — a short, precise title for the proposal
2. Motivation — why this change is needed, what problem it solves
3. Detailed Design — what the implementation looks like
4. Drawbacks — risks and costs of doing this
5. Alternatives — other approaches considered and why rejected
6. Adoption Strategy — how teams will adopt the change
7. Unresolved Questions — open questions for reviewers

When all sections are complete, say exactly: "INTERVIEW_COMPLETE" on its own
line, then summarise the RFC in 2 sentences.

RFC template format to follow:
{rfc_template}
```

The `{rfc_template}` placeholder is replaced at runtime with the contents of `docs-cms/templates/rfc-000-template.md`, fetched from GitHub.

### Draft Generation

After the confirmation stage, the session enters `generating`:

```swift
func generateDraft() async throws -> String {
    let systemPrompt = """
    You are an expert technical writer. Given the following interview answers,
    write a complete RFC document in the exact markdown format of the template
    provided. Use formal technical prose. Fill all sections completely. Do not
    add sections not in the template. Do not include meta-instructions or
    placeholders in the output.

    Today's date: \(ISO8601DateFormatter().string(from: Date()))
    Author: \(KeychainHelper.load(key: "hermit.author.name") ?? "Engineering Team")

    RFC Template:
    \(rfcTemplate)

    Interview Answers:
    Title: \(answers.title)
    Motivation: \(answers.motivation)
    Detailed Design: \(answers.detailedDesign)
    Drawbacks: \(answers.drawbacks)
    Alternatives: \(answers.alternatives)
    Adoption Strategy: \(answers.adoptionStrategy)
    Unresolved Questions: \(answers.unresolvedQuestions)
    """

    let messages = [ChatMessage(role: .system, content: systemPrompt)]
    return try await provider.chat(messages: messages)
}
```

The generated markdown is validated (frontmatter present, all sections present) before moving to the `review` stage.

## Interview View

`RFCInterviewView.swift` is shared between macOS and iPadOS. On macOS it opens in a dedicated `NSPanel`; on iPadOS it presents as a full-screen sheet.

### Layout

```text
┌────────────────────────────────────────────┐
│ New RFC                              [✕]   │
│ ──────────────────────────────────────────  │
│                                            │
│  🤖  "What's the title of your RFC?        │
│       Keep it short and precise."          │
│                                            │
│  👤  "Native Swift app for Hermit"         │
│                                            │
│  🤖  "Got it — you want to call this       │
│       'Native Swift App for Hermit'.       │
│       Is that right?"                      │
│                                            │
│  👤  [TextEditor]                          │
│      "Yes"                                 │
│ ──────────────────────────────────────────  │
│  Stage 1/7 ████░░░░░░░░░░░░  [🎤 Voice]  │
└────────────────────────────────────────────┘
```

- Chat bubble layout: AI bubbles on left, user bubbles on right.
- Progress bar showing interview stage completion.
- "Voice" toggle activates hands-free mode for the current and subsequent answers (rfc-011).
- "✕" shows a confirmation dialog: "Discard draft?" — answers are held in memory and lost on dismiss.

### Text-Only Fallback

If no AI provider is configured (`NullAIProvider`), the interview view becomes a structured form — one field per RFC section, with placeholder hints. The user fills in the form manually and the app assembles the markdown without AI assistance. The "AI assist" badge in the toolbar indicates the current mode.

## RFC Preview

After draft generation, the `review` stage shows `RFCPreviewView.swift`:

- The generated markdown is rendered in a `WKWebView` (same renderer as reading).
- A "Raw Markdown" toggle shows the raw text for manual editing in a `TextEditor`.
- "Edit" button returns to the interview with the current answers pre-filled for revision.
- "Publish as PR" button proceeds to the publishing flow (rfc-012).

# Drawbacks

- AI draft quality depends on the provider and the engineer's answer quality. Poor or terse answers produce poor drafts. The acknowledgement/confirmation loop mitigates this but cannot eliminate it.
- Apple Intelligence's `FoundationModels` framework is new (macOS 15.2+ / iOS 18.2+) and the model capability is more limited than GPT-4o. Long, complex detailed design sections may require more editing when using Apple Intelligence.
- The interview flow adds latency compared to opening a blank document. Engineers who know exactly what they want to write may prefer to skip the interview. A "blank canvas" bypass option should be provided.

# Alternatives

## Alternative 1: Freeform Dictation

Engineer talks freely for 5 minutes; AI structures the transcript into RFC sections at the end. Simpler implementation but produces less reliable structure — the AI must infer section boundaries from unstructured speech. The conversational interview is more reliable and also serves as a forcing function for thinking through each section.

## Alternative 2: Template Fill with AI Suggestions

Show the RFC template with each section as an editable field. An "Improve with AI" button per field sends the current text to the AI for rewriting. More engineer-controlled but loses the guided thinking benefit of the interview format.

# Adoption Strategy

The interview flow is always opt-in. Engineers can create RFCs by typing directly into the preview editor if they prefer. The AI-assisted interview is the default because it produces better first drafts, but it is never mandatory.

# Unresolved Questions

- Should the AI be able to ask follow-up questions beyond the one acknowledgement turn? For example, if an engineer's "Detailed Design" answer is very short, should the AI probe further? This risks feeling annoying. Initial implementation is fixed at one acknowledgement turn per section.
- Should interview progress be persisted to disk so an engineer can resume a half-finished interview after the app is closed? Yes, but deferred to a follow-up — `UserDefaults` serialisation of `InterviewAnswers` is straightforward.
- How should the app handle AI provider rate limiting or errors mid-interview? Show an inline error with a "Retry" button; do not lose the engineer's answers.

# Future Possibilities

- Multi-RFC context: the AI can be shown existing RFCs in the repo to avoid overlapping proposals and to suggest relevant references.
- Team style guide injection: organisations can define custom RFC style guides that the AI incorporates into the system prompt.
- RFC quality scoring: after generation, the AI evaluates the draft against a rubric (completeness, specificity, clarity) and surfaces a score with suggestions.