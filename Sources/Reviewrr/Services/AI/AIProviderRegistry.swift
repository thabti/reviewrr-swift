import Foundation

/// A model id offered in the picker, plus a short human label. The picker
/// also accepts free text (see `AIProviderSettingsView`) — this list is
/// suggestions, not an allowlist, since providers add models faster than
/// Reviewrr ships.
struct AIModelOption: Identifiable, Equatable {
    var id: String { modelID }
    var modelID: String
    var label: String
}

/// How much pull-request context a provider can be given.
///
/// Only the on-device model needs one today: every other backend here takes
/// more than `Prompts` will ever build. Callers pass it into
/// `Prompts.buildContext` so the bound is applied while the context is
/// assembled — trimming afterwards would cut a patch mid-hunk and leave the
/// cache key describing context that was never sent.
struct AIContextBudget: Equatable {
    var maxFileChars: Int
    var maxTotalChars: Int
}

struct AIProviderDescriptor: Identifiable, Equatable {
    var id: String
    var displayName: String
    var needsAPIKey: Bool
    /// Whether this provider needs a user-supplied base URL (the generic
    /// "OpenAI-compatible" entry) in addition to, or instead of, a key.
    var needsBaseURL: Bool
    var defaultModel: String
    var models: [AIModelOption]
    var supportsStreaming: Bool
    var supportsReasoningEffort: Bool
    /// Set for providers that run a CLI on this machine instead of calling an
    /// HTTP API. They hold no key of Reviewrr's — the tool uses the
    /// reviewer's own credentials — so "configured" means "the binary is
    /// installed", which `AgentAvailabilityProbe` answers.
    var localAgent: AgentBinarySpec? = nil
    /// Effort values offered in the picker. Agent CLIs accept a wider set
    /// than the HTTP providers do.
    var efforts: [String] = ["low", "medium", "high"]
    /// Tighter context bound than `Prompts`' default, when the backend needs
    /// one. `nil` means the default is already inside its window.
    var contextBudget: AIContextBudget? = nil

    var keychainAccount: String { KeychainStore.Account.aiProvider(id) }
}

/// Describes every AI backend Reviewrr can talk to. This is metadata only —
/// building a live `AIProvider` from a descriptor (reading its key from the
/// Keychain, its base URL from `AIProviderPreferences`) is `AIProviderFactory`'s
/// job, kept separate so this list stays test-friendly with no I/O.
enum AIProviderRegistry {
    static let anthropic = AIProviderDescriptor(
        id: "anthropic",
        displayName: "Anthropic",
        needsAPIKey: true,
        needsBaseURL: false,
        defaultModel: "claude-opus-5",
        models: [
            AIModelOption(modelID: "claude-opus-5", label: "Claude Opus 5"),
            AIModelOption(modelID: "claude-sonnet-5", label: "Claude Sonnet 5"),
            AIModelOption(modelID: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: true
    )

    static let openAI = AIProviderDescriptor(
        id: "openai",
        displayName: "OpenAI",
        needsAPIKey: true,
        needsBaseURL: false,
        defaultModel: "gpt-4o-mini",
        models: [
            AIModelOption(modelID: "gpt-4o-mini", label: "GPT-4o mini"),
            AIModelOption(modelID: "gpt-4o", label: "GPT-4o"),
            AIModelOption(modelID: "gpt-4.1", label: "GPT-4.1"),
            AIModelOption(modelID: "gpt-4.1-mini", label: "GPT-4.1 mini"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: false
    )

    static let openRouter = AIProviderDescriptor(
        id: "openrouter",
        displayName: "OpenRouter",
        needsAPIKey: true,
        needsBaseURL: false,
        defaultModel: "openrouter/auto",
        models: [
            AIModelOption(modelID: "openrouter/auto", label: "Auto (OpenRouter router)"),
            AIModelOption(modelID: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5"),
            AIModelOption(modelID: "openai/gpt-4o-mini", label: "GPT-4o mini"),
            AIModelOption(modelID: "meta-llama/llama-3.1-70b-instruct", label: "Llama 3.1 70B"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: false
    )

    static let openAICompatible = AIProviderDescriptor(
        id: "openai-compatible",
        displayName: "OpenAI-compatible",
        needsAPIKey: false,
        needsBaseURL: true,
        defaultModel: "",
        models: [],
        supportsStreaming: true,
        supportsReasoningEffort: false
    )

    static let ollama = AIProviderDescriptor(
        id: "ollama",
        displayName: "Ollama (local)",
        needsAPIKey: false,
        needsBaseURL: false,
        defaultModel: "llama3.1",
        models: [
            AIModelOption(modelID: "llama3.1", label: "Llama 3.1"),
            AIModelOption(modelID: "qwen2.5-coder", label: "Qwen 2.5 Coder"),
            AIModelOption(modelID: "deepseek-r1", label: "DeepSeek R1"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: false
    )

    /// Apple's on-device model. The default provider where the system
    /// supports it: nothing to configure, nothing to pay for, and the prompt
    /// never leaves the Mac.
    static let appleIntelligence = AIProviderDescriptor(
        id: "apple-intelligence",
        displayName: "Apple Intelligence (on device)",
        needsAPIKey: false,
        needsBaseURL: false,
        // Not a selectable model id — the system owns the weights, and the
        // picker has nothing to offer. Named so the analysis header and the
        // cache key say which model answered.
        defaultModel: "apple-on-device",
        models: [],
        supportsStreaming: true,
        supportsReasoningEffort: false,
        efforts: [],
        // A few thousand tokens, shared with the instructions and the answer.
        // Whole files do not fit; a per-file slice of the diff does.
        contextBudget: AIContextBudget(maxFileChars: 900, maxTotalChars: 7000)
    )

    /// Local agent CLIs. Reviewrr spawns these read-only, in a throwaway
    /// working directory, and never holds a key for them; the security trade
    /// is stated in `docs/ai-providers.md`.
    static let codex = AIProviderDescriptor(
        id: "codex",
        displayName: "Codex CLI",
        needsAPIKey: false,
        needsBaseURL: false,
        defaultModel: "gpt-5.6-sol",
        models: [
            AIModelOption(modelID: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
            AIModelOption(modelID: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
            AIModelOption(modelID: "gpt-5.6", label: "GPT-5.6"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: true,
        localAgent: .codex,
        efforts: ["low", "medium", "high", "xhigh"]
    )

    static let claudeAgent = AIProviderDescriptor(
        id: "claude-agent",
        displayName: "Claude Code CLI",
        needsAPIKey: false,
        needsBaseURL: false,
        defaultModel: "claude-sonnet-5",
        models: [
            AIModelOption(modelID: "claude-opus-5", label: "Claude Opus 5"),
            AIModelOption(modelID: "claude-sonnet-5", label: "Claude Sonnet 5"),
            AIModelOption(modelID: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
        ],
        supportsStreaming: true,
        supportsReasoningEffort: true,
        localAgent: .claudeAgent,
        efforts: ["low", "medium", "high", "xhigh"]
    )

    static let kiro = AIProviderDescriptor(
        id: "kiro",
        displayName: "Kiro CLI (ACP)",
        needsAPIKey: false,
        needsBaseURL: false,
        // Kiro picks its own default when no model is named, and its model
        // list is account-dependent, so free text in the picker is the honest
        // affordance here.
        defaultModel: "",
        models: [],
        supportsStreaming: true,
        supportsReasoningEffort: true,
        localAgent: .kiro,
        efforts: ["low", "medium", "high", "xhigh"]
    )

    static let openCode = AIProviderDescriptor(
        id: "opencode",
        displayName: "OpenCode (ACP)",
        needsAPIKey: false,
        needsBaseURL: false,
        defaultModel: "",
        models: [],
        supportsStreaming: true,
        // OpenCode's ACP surface has no effort control; showing one would
        // promise a setting the request cannot carry.
        supportsReasoningEffort: false,
        localAgent: .openCode,
        efforts: []
    )

    static let all: [AIProviderDescriptor] = [
        appleIntelligence, anthropic, openAI, openRouter, openAICompatible, ollama,
        codex, claudeAgent, kiro, openCode,
    ]

    static func descriptor(for id: String) -> AIProviderDescriptor {
        all.first { $0.id == id } ?? anthropic
    }
}
