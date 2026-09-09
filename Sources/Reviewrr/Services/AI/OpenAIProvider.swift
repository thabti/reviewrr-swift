import Foundation

struct OpenAIProvider: AIProvider {
    let id = "openai"
    var apiKey: String

    private var client: OpenAICompatibleChatClient {
        OpenAICompatibleChatClient(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: apiKey,
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
