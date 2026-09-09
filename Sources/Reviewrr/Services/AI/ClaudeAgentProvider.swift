import Foundation

/// The Claude Code CLI as an `AIProvider`.
///
/// Same server-agent mechanism as `CodexAgentProvider` — a local process, an
/// empty ephemeral cwd, no key held by Reviewrr — with Claude's own flags:
/// `--restricted` drops the command-running tools and `--permission-mode
/// dontAsk` refuses anything else rather than blocking on a prompt no one can
/// answer; `--max-turns 1` keeps a review question from turning into an
/// agentic loop.
struct ClaudeAgentProvider: AIProvider {
    let id = AIProviderRegistry.claudeAgent.id
    var executablePath: String
    var timeout: TimeInterval

    init(executablePath: String, timeout: TimeInterval = AgentEnvironment.defaultTimeout) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    static func arguments(model: String, effort: String?) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--permission-mode", "dontAsk",
            "--restricted",
            "--max-turns", "1",
        ]
        if let effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        return arguments
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await stream(request) { _ in }
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let started = Date()
        let model = request.model.isEmpty ? AIProviderRegistry.claudeAgent.defaultModel : request.model
        let effort = AgentEffort.normalized(request.reasoningEffort)
        let collector = ClaudeAgentEventCollector(onChunk: onChunk)

        let output: AgentProcessOutput
        do {
            output = try await AgentProcess.run(
                executable: executablePath,
                arguments: Self.arguments(model: model, effort: effort),
                stdin: AgentPrompt.flatten(request),
                timeout: timeout,
                collectStdout: false,
                onLine: { line in collector.consume(line) }
            )
        } catch let error as AgentProcessError {
            throw AgentProviderMapping.aiError(error, providerName: AIProviderRegistry.claudeAgent.displayName)
        }

        if let failure = collector.failureMessage {
            throw AIProviderError.invalidResponse("\(AIProviderRegistry.claudeAgent.displayName): \(failure)")
        }
        guard output.exitCode == 0 else {
            throw AgentProviderMapping.aiError(
                AgentProcessError.exited(binary: "claude", code: output.exitCode, stderr: output.stderr),
                providerName: AIProviderRegistry.claudeAgent.displayName
            )
        }
        let text = collector.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("Claude Code finished without producing an answer.")
        }
        return AIResponse(
            text: text, model: collector.reportedModel ?? model,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            usage: collector.usage
        )
    }
}

/// Parses `claude --print --output-format stream-json`.
///
/// Text arrives twice — as `text_delta` chunks and again in the final
/// `result` — so the deltas drive the live view and the `result` replaces the
/// accumulated text at the end, which also repairs any chunk lost to a
/// truncated line.
final class ClaudeAgentEventCollector {
    private let lock = NSLock()
    private var streamed = ""
    private var finalText: String?
    private(set) var usage: AIUsage?
    private(set) var reportedModel: String?
    private(set) var failureMessage: String?
    private let onChunk: (String) -> Void

    init(onChunk: @escaping (String) -> Void) {
        self.onChunk = onChunk
    }

    var text: String {
        lock.locked { finalText ?? streamed }
    }

    func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let chunk = delta["text"] as? String, !chunk.isEmpty {
                lock.locked { streamed += chunk }
                onChunk(chunk)
            }
            if event["type"] as? String == "message_start",
               let message = event["message"] as? [String: Any],
               let model = message["model"] as? String {
                lock.locked { reportedModel = model }
            }
        case "result":
            if object["is_error"] as? Bool == true {
                let message = object["result"] as? String ?? object["error"] as? String ?? "the run reported an error"
                lock.locked { if failureMessage == nil { failureMessage = message } }
                return
            }
            if let result = object["result"] as? String, !result.isEmpty {
                lock.locked { finalText = result }
            }
            if let usageObject = object["usage"] as? [String: Any] {
                lock.locked {
                    usage = AIUsage(
                        inputTokens: usageObject["input_tokens"] as? Int,
                        outputTokens: usageObject["output_tokens"] as? Int
                    )
                }
            }
        case "error":
            let message = object["message"] as? String ?? "the run failed without a message"
            lock.locked { if failureMessage == nil { failureMessage = message } }
        default:
            return
        }
    }
}
