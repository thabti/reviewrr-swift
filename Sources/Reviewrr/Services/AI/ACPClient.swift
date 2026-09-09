import Foundation

/// A minimal Agent Client Protocol v1 client: JSON-RPC 2.0, one object per
/// line, over an agent's stdio.
///
/// Only what a review conversation needs is implemented — `initialize`,
/// `session/new`, an optional config option, and `session/prompt` — because
/// `ADR-0004` limits Reviewrr to advertising client capabilities it actually
/// honours. Filesystem and terminal capabilities are advertised as absent and
/// any request for them is refused, which is a protocol boundary, not an OS
/// sandbox: the agent still runs with the reviewer's privileges.
final class ACPClient {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    private let session: AgentProcessSession
    private var nextID = 1

    init(session: AgentProcessSession) {
        self.session = session
    }

    // MARK: - Wire

    private func claimID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func send(_ object: [String: Any]) {
        guard
            // `withoutEscapingSlashes` keeps method names readable as
            // `session/new` rather than `session\/new`: both are valid JSON,
            // but only one is greppable in a transcript.
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        session.writeStdin(line + "\n", thenClose: false)
    }

    private func request(id: Int, method: String, params: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func respond(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(id: Any, errorCode: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
    }

    // MARK: - Conversation

    /// Runs one full ACP exchange and returns the agent's answer.
    ///
    /// The whole protocol lives in a single pass over stdout rather than a
    /// general-purpose dispatcher: an agent may interleave notifications,
    /// permission requests, and replies freely, and one loop that knows which
    /// id it is waiting for is both smaller and easier to reason about than a
    /// continuation registry.
    func runPrompt(
        prompt: String,
        model: String?,
        workingDirectory: URL,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        var answer = ""
        var stage = Stage.initializing
        var sessionID: String?
        var pendingModelRequestID: Int?

        let initializeID = claimID()
        request(id: initializeID, method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ])

        var awaitingID = initializeID

        for await line in session.stdoutLines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            // Agent -> client request. Everything is refused; nothing here can
            // read or write the reviewer's disk.
            if let method = message["method"] as? String, let id = message["id"] {
                switch method {
                case "session/request_permission":
                    respond(id: id, result: ["outcome": Self.refusal(for: message["params"] as? [String: Any])])
                default:
                    respond(id: id, errorCode: -32601, message: "Reviewrr does not implement \(method).")
                }
                continue
            }

            // Notification: the only one that matters is streamed text.
            if let method = message["method"] as? String, message["id"] == nil {
                guard method == "session/update",
                      let params = message["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "agent_message_chunk",
                      let content = update["content"] as? [String: Any],
                      let text = content["text"] as? String, !text.isEmpty
                else { continue }
                answer += text
                onChunk(text)
                continue
            }

            guard let id = message["id"] as? Int else { continue }

            // A rejected model option is not fatal — the agent keeps its
            // configured model and the reviewer still gets an answer, which
            // beats refusing to run. Any other error ends the turn.
            if let error = message["error"] as? [String: Any], id != pendingModelRequestID {
                throw Failure(message: Self.describe(error))
            }

            if id == pendingModelRequestID {
                pendingModelRequestID = nil
                let promptID = claimID()
                awaitingID = promptID
                stage = .prompting
                sendPrompt(id: promptID, sessionID: sessionID ?? "", prompt: prompt)
                continue
            }

            guard id == awaitingID else { continue }
            let result = message["result"] as? [String: Any] ?? [:]

            switch stage {
            case .initializing:
                let sessionRequestID = claimID()
                awaitingID = sessionRequestID
                stage = .creatingSession
                request(id: sessionRequestID, method: "session/new", params: [
                    "cwd": workingDirectory.path,
                    "mcpServers": [],
                ])
            case .creatingSession:
                guard let newSessionID = result["sessionId"] as? String else {
                    throw Failure(message: "The agent did not return a session id.")
                }
                sessionID = newSessionID
                if let model, !model.isEmpty, Self.offersModelOption(result) {
                    let modelRequestID = claimID()
                    pendingModelRequestID = modelRequestID
                    request(id: modelRequestID, method: "session/set_config_option", params: [
                        "sessionId": newSessionID, "configId": "model", "value": model,
                    ])
                } else {
                    let promptID = claimID()
                    awaitingID = promptID
                    stage = .prompting
                    sendPrompt(id: promptID, sessionID: newSessionID, prompt: prompt)
                }
            case .prompting:
                return answer
            }
        }

        // stdout closed before the prompt was answered.
        let stderr = session.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
        if !answer.isEmpty { return answer }
        throw Failure(
            message: stderr.isEmpty
                ? "The agent exited before answering."
                : "The agent exited before answering: \(AgentProcess.lastLines(stderr, count: 3))"
        )
    }

    private func sendPrompt(id: Int, sessionID: String, prompt: String) {
        request(id: id, method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": prompt]],
        ])
    }

    private enum Stage {
        case initializing, creatingSession, prompting
    }

    /// Whether `session/new` advertised a selectable model. Sending
    /// `session/set_config_option` blind would make an agent that has no such
    /// option fail a request it never needed to see.
    static func offersModelOption(_ sessionResult: [String: Any]) -> Bool {
        guard let options = sessionResult["configOptions"] as? [[String: Any]] else { return false }
        return options.contains { ($0["id"] as? String) == "model" }
    }

    /// How to say no to a tool request.
    ///
    /// Rejecting the single call keeps the turn alive, so the agent can answer
    /// from what it already has; `cancelled` ends the whole turn and is only
    /// the fallback for an agent that offered no reject option.
    static func refusal(for params: [String: Any]?) -> [String: Any] {
        let options = params?["options"] as? [[String: Any]] ?? []
        let rejectKinds = ["reject_once", "reject_always"]
        if let option = options.first(where: { rejectKinds.contains(($0["kind"] as? String) ?? "") }),
           let optionID = option["optionId"] as? String {
            return ["outcome": "selected", "optionId": optionID]
        }
        return ["outcome": "cancelled"]
    }

    static func describe(_ error: [String: Any]) -> String {
        let message = error["message"] as? String ?? "The agent reported an error."
        if let data = error["data"] as? String, !data.isEmpty { return "\(message): \(data)" }
        return message
    }
}
