import Foundation

/// Kiro and OpenCode, spoken to over ACP.
///
/// Both ship an `acp` subcommand that speaks the protocol on stdio, so one
/// provider covers both; only the launch arguments and how the model is
/// chosen differ. Kiro takes `--model`/`--effort` on the command line;
/// OpenCode exposes the model as a session config option instead (verified
/// against opencode 1.18.x, which answers `session/set_config_option` with a
/// `configId`).
struct ACPAgentProvider: AIProvider {
    let id: String
    var displayName: String
    var executablePath: String
    /// Arguments before any model/effort flags — `["acp"]` for both today.
    var baseArguments: [String]
    /// Whether the model belongs on the command line (Kiro) or is negotiated
    /// after `session/new` (OpenCode).
    var passesModelAsArgument: Bool
    var passesEffortAsArgument: Bool
    var timeout: TimeInterval

    init(
        id: String, displayName: String, executablePath: String, baseArguments: [String],
        passesModelAsArgument: Bool, passesEffortAsArgument: Bool,
        timeout: TimeInterval = AgentEnvironment.defaultTimeout
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.baseArguments = baseArguments
        self.passesModelAsArgument = passesModelAsArgument
        self.passesEffortAsArgument = passesEffortAsArgument
        self.timeout = timeout
    }

    static func kiro(executablePath: String, timeout: TimeInterval = AgentEnvironment.defaultTimeout) -> ACPAgentProvider {
        ACPAgentProvider(
            id: AIProviderRegistry.kiro.id, displayName: AIProviderRegistry.kiro.displayName,
            executablePath: executablePath, baseArguments: ["acp"],
            passesModelAsArgument: true, passesEffortAsArgument: true, timeout: timeout
        )
    }

    static func openCode(executablePath: String, timeout: TimeInterval = AgentEnvironment.defaultTimeout) -> ACPAgentProvider {
        ACPAgentProvider(
            id: AIProviderRegistry.openCode.id, displayName: AIProviderRegistry.openCode.displayName,
            executablePath: executablePath, baseArguments: ["acp"],
            passesModelAsArgument: false, passesEffortAsArgument: false, timeout: timeout
        )
    }

    func arguments(model: String, effort: String?) -> [String] {
        var arguments = baseArguments
        if passesModelAsArgument, !model.isEmpty { arguments += ["--model", model] }
        if passesEffortAsArgument, let effort, !effort.isEmpty { arguments += ["--effort", effort] }
        return arguments
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await stream(request) { _ in }
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let started = Date()
        let descriptor = AIProviderRegistry.descriptor(for: id)
        let model = request.model.isEmpty ? descriptor.defaultModel : request.model
        let effort = AgentEffort.normalized(request.reasoningEffort)

        let workspace = try AgentWorkspace.makeEphemeral()
        defer { workspace.remove() }

        let session: AgentProcessSession
        do {
            session = try AgentProcessSession.launch(
                executable: executablePath,
                arguments: arguments(model: model, effort: effort),
                environment: AgentEnvironment.childEnvironment(),
                workingDirectory: workspace.url
            )
        } catch let error as AgentProcessError {
            throw AgentProviderMapping.aiError(error, providerName: displayName)
        }

        let timedOut = TimeoutFlag()
        // Silence, not duration. A streamed answer that takes four minutes is
        // a working agent; one that says nothing for the idle budget is not.
        let watchdog = AgentProcess.IdleWatchdog(idleTimeout: timeout) {
            timedOut.set()
            session.terminate()
        }
        defer {
            watchdog.cancel()
            session.terminate()
        }

        let client = ACPClient(session: session)
        let text: String
        do {
            text = try await withTaskCancellationHandler {
                try await client.runPrompt(
                    prompt: AgentPrompt.flatten(request),
                    model: passesModelAsArgument ? nil : model,
                    workingDirectory: workspace.url,
                    onChunk: { chunk in
                        // Every streamed token pushes the stall deadline out.
                        watchdog.touch()
                        onChunk(chunk)
                    }
                )
            } onCancel: {
                session.terminate()
            }
        } catch {
            if timedOut.isSet {
                throw AgentProviderMapping.aiError(
                    AgentProcessError.timedOut(
                        binary: (executablePath as NSString).lastPathComponent, seconds: timeout,
                        stderr: session.stderrText()
                    ),
                    providerName: displayName
                )
            }
            if error is CancellationError { throw error }
            throw AIProviderError.invalidResponse("\(displayName): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }

        if timedOut.isSet {
            throw AgentProviderMapping.aiError(
                AgentProcessError.timedOut(
                    binary: (executablePath as NSString).lastPathComponent, seconds: timeout,
                    stderr: session.stderrText()
                ),
                providerName: displayName
            )
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("\(displayName) finished without producing an answer.")
        }
        return AIResponse(
            text: text, model: model,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            // ACP carries no usage numbers, and inventing them would be worse
            // than the panel simply omitting the token row.
            usage: nil
        )
    }
}
