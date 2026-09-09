import Foundation

/// One turn's worth of conversation sent to a provider. Providers translate
/// this into their own wire shape (Anthropic splits `system` out of
/// `messages`, Ollama/OpenAI keep it inline, and so on).
struct AIRequest {
    var system: String?
    var messages: [ChatMessage]
    /// The model id to call. Empty means "use the provider's default" —
    /// callers resolve that from `AIProviderRegistry` before building the
    /// request so every provider implementation can assume a concrete id.
    var model: String
    /// `"low"` / `"medium"` / `"high"` / etc. Providers that don't support
    /// reasoning effort ignore this.
    var reasoningEffort: String?
    var maxOutputTokens: Int = 4096
    /// Asks the provider to return exactly one JSON object and nothing
    /// else. Used for structured analysis; ignored for Ask.
    var jsonMode: Bool = false

    init(
        system: String? = nil, messages: [ChatMessage], model: String,
        reasoningEffort: String? = nil, maxOutputTokens: Int = 4096, jsonMode: Bool = false
    ) {
        self.system = system
        self.messages = messages
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.jsonMode = jsonMode
    }
}

struct AIUsage: Codable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
}

struct AIResponse: Equatable {
    var text: String
    var model: String
    var elapsedMS: Int
    var usage: AIUsage?
}

/// Every failure category the UI needs to explain itself, without ever
/// inventing a message the provider didn't give us or echoing a key back.
enum AIProviderError: LocalizedError, Equatable {
    case missingAPIKey(providerName: String, whereToConfigure: String)
    case missingConfiguration(String)
    case network(String)
    /// A local agent that stopped producing output. Distinct from `network`
    /// because nothing was on a network: the reviewer's own machine ran a
    /// command-line tool and it went quiet, and "Network error" sends them
    /// looking at their wifi instead of at the agent.
    case agentStalled(String)
    case http(status: Int, message: String)
    case cancelled
    case invalidResponse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let providerName, let whereToConfigure):
            return "\(providerName) needs an API key. Add one in \(whereToConfigure)."
        case .missingConfiguration(let message):
            return message
        case .network(let message):
            return "Network error: \(message)"
        case .agentStalled(let message):
            return message
        case .http(let status, let message):
            return "Provider returned HTTP \(status): \(message)"
        case .cancelled:
            return "Cancelled."
        case .invalidResponse(let message):
            return "Unexpected response: \(message)"
        case .unsupported(let message):
            return message
        }
    }
}

/// A read-only assistant backend: given a request, produce text. Nothing in
/// this protocol — or any conformer — may write to GitHub, the filesystem,
/// or the diff; that boundary is enforced entirely above this layer (see
/// `AIModel` and the product-vision "AI as a quiet companion" doc).
protocol AIProvider {
    var id: String { get }
    func complete(_ request: AIRequest) async throws -> AIResponse
    /// Streams incrementally decoded text via `onChunk`, then returns the
    /// same completed `AIResponse` a non-streaming call would. The default
    /// implementation falls back to one `complete()` call delivered as a
    /// single chunk, for a provider that has no incremental API.
    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse
}

extension AIProvider {
    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let response = try await complete(request)
        onChunk(response.text)
        return response
    }
}

/// Shared HTTP plumbing every provider implementation reaches for: a bounded
/// timeout and no transparent disk cache (a stale cached "answer" would be
/// worse than a slow one).
enum AIHTTP {
    static func session(timeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }
}
