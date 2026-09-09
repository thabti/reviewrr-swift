import Foundation

/// Builds a live `AIProvider` from a descriptor plus whatever that provider
/// needs to exist: a Keychain key, a base URL, an installed binary, or a
/// serviceable on-device model.
///
/// This is the promise `AIProviderRegistry`'s documentation has always made —
/// the registry is metadata with no I/O, and this is the one place that turns
/// metadata into something that can answer. Nothing above this layer should
/// know how any individual provider is constructed; before this existed, a
/// thirty-line switch over provider ids lived in a view model.
enum AIProviderFactory {
    /// What a provider needs before it can be built, so the UI can explain a
    /// gap without trying and failing.
    enum Readiness: Equatable {
        case ready
        case needsAPIKey(providerName: String)
        case needsBaseURL(providerName: String)
        case needsBinary(command: String, envVar: String)
        case unavailable(reason: String)

        var isReady: Bool { self == .ready }
    }

    /// Everything the factory reads from outside itself, injected so tests
    /// can build any provider without touching the Keychain, `UserDefaults`,
    /// or the filesystem.
    struct Environment {
        var apiKey: (String) -> String?
        var baseURL: (String) -> URL?
        var binaryPath: (AgentBinarySpec) -> String?
        var appleIntelligence: () -> AppleIntelligenceAvailability
        var ollamaEndpoint: () -> (endpoint: String, model: String)

        static func live(settings: AppSettings) -> Environment {
            Environment(
                apiKey: { KeychainStore.load(account: KeychainStore.Account.aiProvider($0)) },
                baseURL: { AIProviderPreferences.baseURL(for: $0) },
                binaryPath: { AgentEnvironment.resolvePath(for: $0) },
                appleIntelligence: { AppleIntelligenceAvailability.current() },
                ollamaEndpoint: { (settings.localModelEndpoint, settings.localModelName) }
            )
        }
    }

    static func readiness(for id: String, environment: Environment) -> Readiness {
        let descriptor = AIProviderRegistry.descriptor(for: id)

        if descriptor.id == AIProviderRegistry.appleIntelligence.id {
            let availability = environment.appleIntelligence()
            return availability.isAvailable ? .ready : .unavailable(reason: availability.explanation)
        }
        if let spec = descriptor.localAgent {
            return environment.binaryPath(spec) == nil
                ? .needsBinary(command: spec.commandName, envVar: spec.overrideEnvVar)
                : .ready
        }
        if descriptor.needsBaseURL, environment.baseURL(descriptor.id) == nil {
            return .needsBaseURL(providerName: descriptor.displayName)
        }
        if descriptor.needsAPIKey, environment.apiKey(descriptor.id)?.isEmpty != false {
            return .needsAPIKey(providerName: descriptor.displayName)
        }
        return .ready
    }

    /// The live provider, or `nil` when `readiness` would not say `.ready`.
    /// Callers decide what "not ready" means — a heuristic fallback for
    /// analysis, a clear error for Ask.
    static func make(id: String, environment: Environment) -> AIProvider? {
        guard readiness(for: id, environment: environment).isReady else { return nil }
        let descriptor = AIProviderRegistry.descriptor(for: id)

        switch descriptor.id {
        case AIProviderRegistry.appleIntelligence.id:
            return AppleIntelligenceFactory.makeProvider()
        case AIProviderRegistry.anthropic.id:
            return environment.apiKey(descriptor.id).map { AnthropicProvider(apiKey: $0) }
        case AIProviderRegistry.openAI.id:
            return environment.apiKey(descriptor.id).map { OpenAIProvider(apiKey: $0) }
        case AIProviderRegistry.openRouter.id:
            return environment.apiKey(descriptor.id).map { OpenRouterProvider(apiKey: $0) }
        case AIProviderRegistry.openAICompatible.id:
            guard let baseURL = environment.baseURL(descriptor.id) else { return nil }
            let key = environment.apiKey(descriptor.id)
            return OpenAICompatibleProvider(baseURL: baseURL, apiKey: (key?.isEmpty == false) ? key : nil)
        case AIProviderRegistry.ollama.id:
            let ollama = environment.ollamaEndpoint()
            return LocalModelClient(endpoint: ollama.endpoint, model: ollama.model)
        case AIProviderRegistry.codex.id:
            return environment.binaryPath(.codex).map { CodexAgentProvider(executablePath: $0) }
        case AIProviderRegistry.claudeAgent.id:
            return environment.binaryPath(.claudeAgent).map { ClaudeAgentProvider(executablePath: $0) }
        case AIProviderRegistry.kiro.id:
            return environment.binaryPath(.kiro).map { ACPAgentProvider.kiro(executablePath: $0) }
        case AIProviderRegistry.openCode.id:
            return environment.binaryPath(.openCode).map { ACPAgentProvider.openCode(executablePath: $0) }
        default:
            return nil
        }
    }

    /// The error the panel shows when a provider could not be built. Kept
    /// here so "not installed" is never reported as "missing API key" — the
    /// remedies are completely different.
    static func notReadyError(for id: String, environment: Environment, whereToConfigure: String = "Settings → AI Provider") -> AIProviderError {
        switch readiness(for: id, environment: environment) {
        case .ready:
            return .missingConfiguration("\(AIProviderRegistry.descriptor(for: id).displayName) is configured but could not be started.")
        case .needsAPIKey(let providerName):
            return .missingAPIKey(providerName: providerName, whereToConfigure: whereToConfigure)
        case .needsBaseURL(let providerName):
            return .missingConfiguration("\(providerName) needs a base URL. Add one in \(whereToConfigure).")
        case .needsBinary(let command, let envVar):
            return AgentProviderMapping.aiError(
                AgentProcessError.binaryNotFound(name: command, envVar: envVar),
                providerName: AIProviderRegistry.descriptor(for: id).displayName
            )
        case .unavailable(let reason):
            return .missingConfiguration(reason)
        }
    }
}
