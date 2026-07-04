import Foundation

// MARK: - hermit-uod: OpenAI provider (GPT-4o chat + Whisper transcription)

final class OpenAIProvider: AIProvider {
    let displayName = "OpenAI (GPT-4o)"

    private let apiKey: String
    private let chatModel = "gpt-4o"
    private let session = URLSession.shared

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: Chat completions

    func chat(messages: [AIMessage]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let body: [String: Any] = [
            "model": chatModel,
            "messages": messages.map { ["role": roleName($0.role), "content": $0.content] },
            "temperature": 0.7,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AIError.requestFailed(msg)
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    // MARK: Whisper transcription

    func transcribe(audioData: Data, mimeType: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = UUID().uuidString
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n")
        append("--\(boundary)\r\n")
        let ext = mimeType.contains("mp4") || mimeType.contains("m4a") ? "m4a" : "wav"
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AIError.transcriptionFailed(msg)
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func roleName(_ role: AIMessage.Role) -> String {
        switch role {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "assistant"
        }
    }
}
