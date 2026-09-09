import Foundation

/// The Codex CLI as an `AIProvider`.
///
/// Reviewrr holds no OpenAI key for this path — `codex` reads the reviewer's
/// own `~/.codex` credentials. That is the trade this provider makes against
/// the key-in-app providers: nothing to leak, but a local process runs. Every
/// invocation is `--sandbox read-only` in an empty `--ephemeral` temp cwd, so
/// the agent has no project to read and no session to leave behind.
struct CodexAgentProvider: AIProvider {
    let id = AIProviderRegistry.codex.id
    var executablePath: String
    var timeout: TimeInterval

    init(executablePath: String, timeout: TimeInterval = AgentEnvironment.defaultTimeout) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    /// The exact invocation, kept in one place so the tests can assert it.
    /// `--json` and the trailing `-` are Reviewrr's additions to the agreed
    /// command: JSONL is the only output shape that survives parsing, and
    /// reading the prompt from stdin keeps a large diff out of `argv`.
    static func arguments(model: String, effort: String?) -> [String] {
        var arguments = ["exec", "-m", model]
        if let effort, !effort.isEmpty {
            arguments += ["-c", "model_reasoning_effort=\(effort)"]
        }
        arguments += [
            "--skip-git-repo-check",
            "--ephemeral",
            "--sandbox", "read-only",
            "--color", "never",
            "--json",
            "-",
        ]
        return arguments
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await stream(request) { _ in }
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let started = Date()
        let model = request.model.isEmpty ? AIProviderRegistry.codex.defaultModel : request.model
        let effort = AgentEffort.normalized(request.reasoningEffort)
        let prompt = AgentPrompt.flatten(request)

        let collector = CodexEventCollector(onChunk: onChunk)
        let output: AgentProcessOutput
        do {
            output = try await AgentProcess.run(
                executable: executablePath,
                arguments: Self.arguments(model: model, effort: effort),
                stdin: prompt,
                timeout: timeout,
                collectStdout: false,
                onLine: { line in collector.consume(line) }
            )
        } catch let error as AgentProcessError {
            throw AgentProviderMapping.aiError(error, providerName: AIProviderRegistry.codex.displayName)
        }

        if let failure = collector.failureMessage {
            throw AIProviderError.invalidResponse("\(AIProviderRegistry.codex.displayName): \(failure)")
        }
        guard output.exitCode == 0 else {
            throw AgentProviderMapping.aiError(
                AgentProcessError.exited(binary: "codex", code: output.exitCode, stderr: output.stderr),
                providerName: AIProviderRegistry.codex.displayName
            )
        }
        let text = collector.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("Codex finished without producing an answer.")
        }
        return AIResponse(
            text: text, model: model,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            usage: collector.usage
        )
    }
}

/// Turns `codex exec --json` JSONL into text chunks and usage.
///
/// Codex emits whole items rather than token deltas (verified against
/// codex-cli 0.152.x), so "streaming" here is message-granular: the reviewer
/// sees each agent message the moment it lands rather than at process exit.
final class CodexEventCollector {
    private let lock = NSLock()
    private var pieces: [String] = []
    private(set) var usage: AIUsage?
    private(set) var failureMessage: String?
    private let onChunk: (String) -> Void

    init(onChunk: @escaping (String) -> Void) {
        self.onChunk = onChunk
    }

    var text: String {
        lock.locked { pieces.joined(separator: "\n") }
    }

    func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let type = object["type"] as? String else { return }

        switch type {
        case "item.completed", "item.updated":
            guard
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String, !text.isEmpty
            else { return }
            lock.locked { pieces.append(text) }
            onChunk(text)
        case "turn.completed":
            guard let usageObject = object["usage"] as? [String: Any] else { return }
            let input = usageObject["input_tokens"] as? Int
            let output = usageObject["output_tokens"] as? Int
            lock.locked { usage = AIUsage(inputTokens: input, outputTokens: output) }
        case "turn.failed", "error", "thread.error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? object["message"] as? String
                ?? "the run failed without a message"
            lock.locked { if failureMessage == nil { failureMessage = message } }
        default:
            return
        }
    }
}
