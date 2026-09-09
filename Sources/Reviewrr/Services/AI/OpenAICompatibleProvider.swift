import Foundation

/// A user-supplied endpoint speaking the OpenAI Chat Completions shape —
/// LM Studio, vLLM, llama.cpp's server, a corporate gateway, and similar.
/// The API key is optional: many local servers accept any bearer token or
/// none at all.
struct OpenAICompatibleProvider: AIProvider {
    let id = "openai-compatible"
    var baseURL: URL
    var apiKey: String?

    private var client: OpenAICompatibleChatClient {
        OpenAICompatibleChatClient(
            baseURL: baseURL,
            apiKey: apiKey,
            // An arbitrary third-party server is not guaranteed to
            // recognize `stream_options.include_usage`; skip it rather
            // than risk a 400 from a strict implementation.
            includeUsageInStream: false
        )
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await client.complete(request)
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        try await client.stream(request, onChunk: onChunk)
    }
}
