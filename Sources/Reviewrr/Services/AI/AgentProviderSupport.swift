import Foundation

/// Reasoning effort as the agent CLIs spell it.
///
/// Codex, Claude, and Kiro all accept the same five words; anything else the
/// UI or a stored setting might hold collapses to `medium` rather than
/// failing the run with an argument error the reviewer cannot act on.
enum AgentEffort {
    static let all = ["low", "medium", "high", "xhigh", "max"]

    static func normalized(_ raw: String?) -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return "medium"
        }
        return all.contains(value) ? value : "medium"
    }
}

/// Flattens an `AIRequest` into the single prompt string a CLI agent takes.
///
/// These agents have no `system` role and no message array on the wire: one
/// turn goes in, one answer comes out. Roles are kept as labels so the model
/// still sees who said what across an Ask thread.
enum AgentPrompt {
    /// - Parameter includeSystem: `false` for a backend that takes the system
    ///   prompt separately (Apple Intelligence passes it as session
    ///   instructions), so it is not also repeated inside the turn.
    static func flatten(_ request: AIRequest, includeSystem: Bool = true) -> String {
        var sections: [String] = []
        if includeSystem, let system = request.system?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            sections.append(system)
        }
        for message in request.messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch message.role {
            case .system: sections.append(content)
            case .user: sections.append("User:\n\(content)")
            case .assistant: sections.append("Assistant:\n\(content)")
            }
        }
        if request.jsonMode {
            // These agents have no JSON mode flag on the wire, so the contract
            // is restated last where it is hardest to lose. `AnalysisParser`
            // already tolerates a fenced or prose-wrapped object.
            sections.append("Respond with exactly one JSON object and no other text, Markdown, or code fence.")
        }
        return sections.joined(separator: "\n\n")
    }
}

/// Translates process-level failures into the error vocabulary the AI panel
/// already knows how to render.
enum AgentProviderMapping {
    static func aiError(_ error: AgentProcessError, providerName: String) -> AIProviderError {
        switch error {
        case .binaryNotFound:
            return .missingConfiguration(error.errorDescription ?? "\(providerName) is not installed.")
        case .timedOut:
            return .agentStalled(error.errorDescription ?? "\(providerName) stopped responding.")
        case .spawnFailed, .workspaceFailed:
            return .missingConfiguration(error.errorDescription ?? "\(providerName) could not start.")
        case .exited:
            return .invalidResponse(error.errorDescription ?? "\(providerName) failed.")
        }
    }

    /// Resolves the binary for a provider or throws the error the UI shows.
    static func executablePath(for spec: AgentBinarySpec, providerName: String) throws -> String {
        guard let path = AgentEnvironment.resolvePath(for: spec) else {
            throw aiError(
                AgentProcessError.binaryNotFound(name: spec.commandName, envVar: spec.overrideEnvVar),
                providerName: providerName
            )
        }
        return path
    }
}
