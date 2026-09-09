import Foundation

/// A direct HTTP client for the OpenAI Chat Completions wire format
/// (`POST {baseURL}/chat/completions`), shared by the OpenAI, OpenRouter,
/// and generic "OpenAI-compatible" providers — they differ only in base
/// URL, auth header, a couple of optional extra headers, and how much of
/// the newer wire surface (usage-in-stream, JSON response format) the
/// remote server is trusted to understand.
struct OpenAICompatibleChatClient {
    var baseURL: URL
    var apiKey: String?
    var extraHeaders: [String: String] = [:]
    var timeout: TimeInterval = 60
    /// A first-party server (OpenAI, OpenRouter) understands
    /// `stream_options.include_usage`; an arbitrary user-supplied
    /// "OpenAI-compatible" endpoint might not, so that provider disables it
    /// rather than risk a 400 from an unrecognized field.
    var includeUsageInStream: Bool = true

    private var endpoint: URL { baseURL.appendingPathComponent("chat/completions") }

    private struct WireMessage: Encodable { let role: String; let content: String }

    private struct RequestBody: Encodable {
        struct StreamOptions: Encodable { let include_usage: Bool }
        struct ResponseFormat: Encodable { let type: String }
        let model: String
        let messages: [WireMessage]
        let max_tokens: Int
        let stream: Bool
        let stream_options: StreamOptions?
        let response_format: ResponseFormat?
    }

    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func wireMessages(_ request: AIRequest) -> [WireMessage] {
        var messages: [WireMessage] = []
        if let system = request.system, !system.isEmpty {
            messages.append(WireMessage(role: "system", content: system))
        }
        messages.append(contentsOf: request.messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) })
        return messages
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let start = Date()
        let body = RequestBody(
            model: request.model, messages: wireMessages(request), max_tokens: request.maxOutputTokens,
            stream: false, stream_options: nil,
            response_format: request.jsonMode ? .init(type: "json_object") : nil
        )
        let data = try JSONEncoder().encode(body)
        let (responseData, http) = try await send(makeRequest(body: data))
        try Self.throwIfError(status: http.statusCode, data: responseData)

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let model: String?
            let usage: Usage?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: responseData)
        } catch {
            throw AIProviderError.invalidResponse("couldn't parse the provider's response")
        }
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIProviderError.invalidResponse("no completion returned")
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return AIResponse(
            text: text, model: decoded.model ?? request.model, elapsedMS: elapsed,
            usage: AIUsage(inputTokens: decoded.usage?.prompt_tokens, outputTokens: decoded.usage?.completion_tokens)
        )
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let start = Date()
        let body = RequestBody(
            model: request.model, messages: wireMessages(request), max_tokens: request.maxOutputTokens,
            stream: true,
            stream_options: includeUsageInStream ? .init(include_usage: true) : nil,
            response_format: request.jsonMode ? .init(type: "json_object") : nil
        )
        let data = try JSONEncoder().encode(body)
        let (bytes, http) = try await bytesResponse(makeRequest(body: data))
        guard (200..<300).contains(http.statusCode) else {
            let collected = try await Self.collect(bytes)
            try Self.throwIfError(status: http.statusCode, data: collected)
            throw AIProviderError.http(status: http.statusCode, message: "request failed")
        }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]?
            let model: String?
            let usage: Usage?
        }

        var text = ""
        var model = request.model
        var usage: AIUsage?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: payloadData)
            else { continue }
            if let modelName = chunk.model, !modelName.isEmpty { model = modelName }
            if let delta = chunk.choices?.first?.delta.content, !delta.isEmpty {
                text += delta
                onChunk(delta)
            }
            if let chunkUsage = chunk.usage {
                usage = AIUsage(inputTokens: chunkUsage.prompt_tokens, outputTokens: chunkUsage.completion_tokens)
            }
        }
        guard !text.isEmpty else { throw AIProviderError.invalidResponse("no completion returned") }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return AIResponse(text: text, model: model, elapsedMS: elapsed, usage: usage)
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

    private func bytesResponse(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
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
