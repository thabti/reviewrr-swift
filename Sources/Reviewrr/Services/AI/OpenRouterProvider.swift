import Foundation

/// OpenRouter speaks the OpenAI Chat Completions wire format at its own
/// host, routing to whichever underlying model the caller names.
struct OpenRouterProvider: AIProvider {
    let id = "openrouter"
    var apiKey: String

    private var client: OpenAICompatibleChatClient {
        OpenAICompatibleChatClient(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKey: apiKey,
            // OpenRouter's own docs ask for these so usage shows up
            // attributed to Reviewrr in a caller's dashboard; harmless if
            // ignored by a request that doesn't care.
            extraHeaders: [
                "HTTP-Referer": "https://github.com/thabti/reviewrr-swift",
                "X-Title": "Reviewrr",
            ],
            includeUsageInStream: true
        )
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await client.complete(request)
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        try await client.stream(request, onChunk: onChunk)
    }
}
