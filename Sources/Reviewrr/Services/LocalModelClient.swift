import Foundation

enum LocalModelError: LocalizedError {
    case endpointUnreachable(Error)
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let error):
            return "Can't reach the local model server: \(error.localizedDescription)"
        case .http(let status, let message):
            return "Local model server returned \(status): \(message)"
        case .emptyResponse:
            return "The local model returned an empty response."
        }
    }
}

/// Talks to a locally running Ollama server (https://github.com/ollama/ollama).
/// No API key, no cloud provider: the endpoint defaults to
/// `http://localhost:11434` and every request stays on the Mac.
struct LocalModelClient {
    var endpoint: String
    var model: String

    private var session: URLSession { .shared }

    private func url(_ path: String) -> URL? {
        URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    func listModels() async throws -> [String] {
        guard let url = url("/api/tags") else { return [] }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw LocalModelError.endpointUnreachable(error)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalModelError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "couldn't list models")
        }
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map(\.name)
    }

    func chat(messages: [ChatMessage]) async throws -> String {
        guard let url = url("/api/chat") else { throw LocalModelError.emptyResponse }
        struct Request: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
        }
        let body = Request(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: false
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelError.endpointUnreachable(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelError.endpointUnreachable(URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LocalModelError.http(http.statusCode, message)
        }
        struct ChatResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard !decoded.message.content.isEmpty else { throw LocalModelError.emptyResponse }
        return decoded.message.content
    }
}

// MARK: - AIProvider

/// Folds the local Ollama client into the same registry as the hosted
/// providers, so the panel's provider picker and `PRAnalyzer` don't need a
/// special case for "no cloud key, runs on this Mac".
extension LocalModelClient: AIProvider {
    var id: String { "ollama" }

    /// `AIRequest.model` wins when set (the panel's model picker can name
    /// any locally pulled model without constructing a new client); this
    /// instance's `model` is only the fallback for a request that left it
    /// blank.
    private func effectiveModel(_ request: AIRequest) -> String {
        request.model.isEmpty ? model : request.model
    }

    private func wireMessages(_ request: AIRequest) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let system = request.system, !system.isEmpty {
            messages.append(ChatMessage(role: .system, content: system))
        }
        messages.append(contentsOf: request.messages)
        return messages
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let start = Date()
        do {
            let text = try await chat(messages: wireMessages(request))
            return AIResponse(text: text, model: effectiveModel(request), elapsedMS: Int(Date().timeIntervalSince(start) * 1000), usage: nil)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch let error as LocalModelError {
            throw Self.mapError(error)
        }
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        guard let url = url("/api/chat") else { throw AIProviderError.missingConfiguration("The Ollama endpoint URL is invalid.") }
        struct Request: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
        }
        let body = Request(
            model: effectiveModel(request),
            messages: wireMessages(request).map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: true
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.timeoutInterval = 300

        let start = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch {
            if (error as? URLError)?.code == .cancelled { throw AIProviderError.cancelled }
            throw AIProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Ollama request failed")
        }

        // Ollama's streaming reply is newline-delimited JSON objects (not
        // SSE): one line per token/chunk, the last one carrying `done: true`
        // plus token counts.
        struct Chunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        var text = ""
        var usage: AIUsage?
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
            if let piece = chunk.message?.content, !piece.isEmpty {
                text += piece
                onChunk(piece)
            }
            if chunk.done == true {
                usage = AIUsage(inputTokens: chunk.prompt_eval_count, outputTokens: chunk.eval_count)
            }
        }
        guard !text.isEmpty else { throw AIProviderError.invalidResponse("Ollama returned an empty response.") }
        return AIResponse(text: text, model: effectiveModel(request), elapsedMS: Int(Date().timeIntervalSince(start) * 1000), usage: usage)
    }

    private static func mapError(_ error: LocalModelError) -> AIProviderError {
        switch error {
        case .endpointUnreachable(let underlying):
            return .network("Can't reach the local Ollama server: \(underlying.localizedDescription)")
        case .http(let status, let message):
            return .http(status: status, message: message)
        case .emptyResponse:
            return .invalidResponse("Ollama returned an empty response.")
        }
    }
}
