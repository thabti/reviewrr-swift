import Foundation

/// Direct HTTP calls to the Anthropic Messages API — see the `claude-api`
/// skill for the request/response/streaming shapes this follows.
/// `anthropic-version: 2023-06-01`, auth via `x-api-key`, and `system` is a
/// top-level field rather than a message with role `system`.
struct AnthropicProvider: AIProvider {
    let id = "anthropic"
    var apiKey: String

    private static let apiBase = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Effort tuning errors on Haiku; only the larger Anthropic models in
    /// the registry accept `output_config.effort`.
    private static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    private func supportsEffort(model: String) -> Bool { !model.contains("haiku") }

    private struct WireMessage: Encodable { let role: String; let content: String }

    private struct RequestBody: Encodable {
        struct OutputConfig: Encodable { let effort: String }
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [WireMessage]
        let stream: Bool
        let output_config: OutputConfig?
    }

    private func makeBody(_ request: AIRequest, stream: Bool) -> RequestBody {
        // Anthropic has no `system`-role message; fold any that slipped
        // into `messages` (callers are expected to use `request.system`
        // instead) into the system prompt so intent isn't silently lost.
        var systemText = request.system ?? ""
        var wireMessages: [WireMessage] = []
        for message in request.messages {
            switch message.role {
            case .system:
                if !systemText.isEmpty { systemText += "\n\n" }
                systemText += message.content
            case .user, .assistant:
                wireMessages.append(WireMessage(role: message.role.rawValue, content: message.content))
            }
        }
        let effort = request.reasoningEffort.flatMap { Self.effortLevels.contains($0) ? $0 : nil }
        let outputConfig = (effort != nil && supportsEffort(model: request.model))
            ? RequestBody.OutputConfig(effort: effort!)
            : nil
        return RequestBody(
            model: request.model,
            max_tokens: request.maxOutputTokens,
            system: systemText.isEmpty ? nil : systemText,
            messages: wireMessages,
            stream: stream,
            output_config: outputConfig
        )
    }

    private func makeRequest(body: RequestBody) throws -> URLRequest {
        var request = URLRequest(url: Self.apiBase)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let start = Date()
        let urlRequest = try makeRequest(body: makeBody(request, stream: false))
        let (data, http) = try await send(urlRequest, timeout: 90)
        try Self.throwIfError(status: http.statusCode, data: data)

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
            let content: [Block]
            let model: String?
            let usage: Usage?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("couldn't parse Anthropic's response")
        }
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse("no completion returned") }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return AIResponse(
            text: text, model: decoded.model ?? request.model, elapsedMS: elapsed,
            usage: AIUsage(inputTokens: decoded.usage?.input_tokens, outputTokens: decoded.usage?.output_tokens)
        )
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let start = Date()
        let urlRequest = try makeRequest(body: makeBody(request, stream: true))
        let (bytes, http) = try await bytesResponse(urlRequest, timeout: 300)
        guard (200..<300).contains(http.statusCode) else {
            let collected = try await Self.collect(bytes)
            try Self.throwIfError(status: http.statusCode, data: collected)
            throw AIProviderError.http(status: http.statusCode, message: "request failed")
        }

        struct Event: Decodable {
            struct Delta: Decodable { let type: String?; let text: String? }
            struct MessageInfo: Decodable {
                struct Usage: Decodable { let input_tokens: Int? }
                let model: String?
                let usage: Usage?
            }
            struct MessageDeltaUsage: Decodable { let output_tokens: Int? }
            let type: String
            let delta: Delta?
            let message: MessageInfo?
            let usage: MessageDeltaUsage?
        }

        var text = ""
        var model = request.model
        var inputTokens: Int?
        var outputTokens: Int?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let payloadData = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: payloadData)
            else { continue }
            switch event.type {
            case "message_start":
                if let messageModel = event.message?.model { model = messageModel }
                inputTokens = event.message?.usage?.input_tokens
            case "content_block_delta":
                if event.delta?.type == "text_delta", let piece = event.delta?.text, !piece.isEmpty {
                    text += piece
                    onChunk(piece)
                }
            case "message_delta":
                if let output = event.usage?.output_tokens { outputTokens = output }
            default:
                break
            }
        }
        guard !text.isEmpty else { throw AIProviderError.invalidResponse("no completion returned") }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return AIResponse(
            text: text, model: model, elapsedMS: elapsed,
            usage: (inputTokens == nil && outputTokens == nil) ? nil : AIUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }

    // MARK: - Transport

    private func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await AIHTTP.session(timeout: timeout).data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIProviderError.network("no HTTP response") }
            return (data, http)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch let error as AIProviderError {
            throw error
        } catch {
            if (error as? URLError)?.code == .cancelled { throw AIProviderError.cancelled }
            throw AIProviderError.network(error.localizedDescription)
        }
    }

    private func bytesResponse(_ request: URLRequest, timeout: TimeInterval) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await AIHTTP.session(timeout: timeout).bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIProviderError.network("no HTTP response") }
            return (bytes, http)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch let error as AIProviderError {
            throw error
        } catch {
            if (error as? URLError)?.code == .cancelled { throw AIProviderError.cancelled }
            throw AIProviderError.network(error.localizedDescription)
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func throwIfError(status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            ?? String(data: data, encoding: .utf8)
            ?? "unknown error"
        throw AIProviderError.http(status: status, message: message)
    }
}
