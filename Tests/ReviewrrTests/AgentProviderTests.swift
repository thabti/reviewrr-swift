import XCTest

/// These tests spawn real processes.
///
/// The provider registry already had a test that only checked adapter shape
/// and name, which proved nothing about whether a request completes. Every
/// test here drives the whole path — argv, `posix_spawn`, process group,
/// stdin, streamed stdout, parsing, exit — against a stub agent written to
/// disk, so it is deterministic and needs no network or model account. The
/// live suite at the bottom runs the same path against the real CLIs when
/// `REVIEWRR_LIVE_AGENT_TESTS=1` is set.
final class AgentProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reviewrr-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes an executable shell script and returns its path.
    @discardableResult
    private func writeScript(_ name: String, _ body: String) throws -> String {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - Codex: a request that actually completes

    func testCodexProviderCompletesARequestThroughASpawnedProcess() async throws {
        let promptSink = scratch.appendingPathComponent("prompt.txt").path
        let argvSink = scratch.appendingPathComponent("argv.txt").path
        let path = try writeScript("codex", """
        printf '%s\\n' "$@" > \(argvSink)
        cat > \(promptSink)
        printf '%s\\n' '{"type":"thread.started","thread_id":"t1"}'
        printf '%s\\n' '{"type":"turn.started"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"AGENT_OK"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":7}}'
        """)

        var chunks: [String] = []
        let provider = CodexAgentProvider(executablePath: path, timeout: 20)
        let response = try await provider.stream(
            AIRequest(system: "System rules.", messages: [ChatMessage(role: .user, content: "Say AGENT_OK")], model: "gpt-5.6-sol", reasoningEffort: "low")
        ) { chunks.append($0) }

        XCTAssertEqual(response.text, "AGENT_OK")
        XCTAssertEqual(chunks, ["AGENT_OK"], "The reviewer must see the answer as it arrives, not only at exit")
        XCTAssertEqual(response.usage, AIUsage(inputTokens: 11, outputTokens: 7))
        XCTAssertEqual(response.model, "gpt-5.6-sol")

        let prompt = try String(contentsOfFile: promptSink, encoding: .utf8)
        XCTAssertTrue(prompt.contains("System rules."), "The system prompt must reach an agent that has no system role")
        XCTAssertTrue(prompt.contains("Say AGENT_OK"))

        let argv = try String(contentsOfFile: argvSink, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, CodexAgentProvider.arguments(model: "gpt-5.6-sol", effort: "low"))
    }

    func testCodexArgumentsMatchTheAgreedInvocation() {
        XCTAssertEqual(
            CodexAgentProvider.arguments(model: "gpt-5.6-sol", effort: "xhigh"),
            [
                "exec", "-m", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=xhigh",
                "--skip-git-repo-check", "--ephemeral",
                "--sandbox", "read-only",
                "--color", "never",
                "--json", "-",
            ]
        )
    }

    func testCodexSurfacesATurnFailureInsteadOfReturningEmptyText() async throws {
        let path = try writeScript("codex-fail", """
        cat > /dev/null
        printf '%s\\n' '{"type":"turn.failed","error":{"message":"usage limit reached"}}'
        """)
        let provider = CodexAgentProvider(executablePath: path, timeout: 20)
        do {
            _ = try await provider.complete(AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "gpt-5.6"))
            XCTFail("A failed turn must not read as success")
        } catch let error as AIProviderError {
            XCTAssertTrue(error.errorDescription?.contains("usage limit reached") == true, "got: \(error)")
        }
    }

    func testCodexReportsANonZeroExitWithTheAgentsOwnStderr() async throws {
        let path = try writeScript("codex-exit", """
        cat > /dev/null
        echo 'not logged in' >&2
        exit 3
        """)
        let provider = CodexAgentProvider(executablePath: path, timeout: 20)
        do {
            _ = try await provider.complete(AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "gpt-5.6"))
            XCTFail("Exit code 3 must surface")
        } catch let error as AIProviderError {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains("exited with code 3"), description)
            XCTAssertTrue(description.contains("not logged in"), description)
        }
    }

    // MARK: - Isolation and lifecycle

    func testAgentRunsInAFreshTemporaryDirectoryThatIsRemovedAfterwards() async throws {
        let path = try writeScript("pwd-agent", "pwd")
        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 20)
        let workingDirectory = try XCTUnwrap(output.stdoutLines.first)

        XCTAssertTrue(
            workingDirectory.contains("reviewrr-agent-"),
            "The agent must run in its own throwaway directory, got \(workingDirectory)"
        )
        XCTAssertFalse(
            workingDirectory.contains(FileManager.default.currentDirectoryPath),
            "The agent must never be handed the reviewer's checkout as its cwd"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workingDirectory),
            "The ephemeral directory must not outlive the request"
        )
    }

    func testAgentRunsInItsOwnProcessGroup() async throws {
        let path = try writeScript("pgid-agent", "ps -o pgid= -p $$ | tr -d ' '")
        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 20)
        let childGroup = try XCTUnwrap(output.stdoutLines.first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
        XCTAssertNotEqual(
            childGroup, getpgrp(),
            "Signalling the agent's group must not signal Reviewrr itself"
        )
    }

    func testChildGetsACleanSignalStateNotSwiftsBlockedAndIgnoredOne() async throws {
        // The regression this pins down: Swift's runtime and libdispatch block
        // signals and ignore SIGPIPE, and `posix_spawn` passes both through, so
        // an agent waiting on a signal produced no output at all until it was
        // killed by the timeout. Kiro and OpenCode both hung this way; the
        // same command wrapped in `/bin/sh` worked, because a shell hands its
        // children a clean state.
        let path = try writeScript("signal-agent", """
        kill -USR1 $$
        echo "SURVIVED_BLOCKED_USR1"
        """)

        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGUSR1)
        var previous = sigset_t()
        sigemptyset(&previous)
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }

        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 20)
        XCTAssertFalse(
            output.stdoutLines.contains("SURVIVED_BLOCKED_USR1"),
            "SIGUSR1 must reach the child and end it; surviving means the parent's blocked mask was inherited"
        )
        XCTAssertEqual(output.exitCode, 128 + SIGUSR1, "Killed by SIGUSR1 reads as 128 + 30")
    }

    func testChildDoesNotInheritAnIgnoredSignalDisposition() async throws {
        let path = try writeScript("ignored-signal-agent", """
        kill -USR2 $$
        echo "SURVIVED_IGNORED_USR2"
        """)

        let previous = signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, previous) }

        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 20)
        XCTAssertFalse(
            output.stdoutLines.contains("SURVIVED_IGNORED_USR2"),
            "An ignored disposition must be reset to default for the child"
        )
        XCTAssertEqual(output.exitCode, 128 + SIGUSR2)
    }

    func testPartialStdoutKeepsAgentAlive() async throws {
        let path = try writeScript("partial-output", """
        for i in 1 2 3 4 5; do
            printf 'progress'
            sleep 0.4
        done
        printf '\n'
        """)
        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 1)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutLines.joined(), String(repeating: "progress", count: 5))
    }

    func testStderrProgressKeepsAgentAlive() async throws {
        let path = try writeScript("stderr-progress", """
        for i in 1 2 3 4 5; do
            printf 'progress' >&2
            sleep 0.4
        done
        echo 'answer'
        """)
        let output = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 1)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutLines, ["answer"])
    }

    func testTimeoutKillsTheWholeProcessTreeNotJustTheEntryPoint() async throws {
        let grandchildMarker = scratch.appendingPathComponent("grandchild.pid").path
        let path = try writeScript("tree-agent", """
        ( sleep 60 ) &
        echo $! > \(grandchildMarker)
        sleep 60
        """)

        do {
            _ = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 1)
            XCTFail("A run past its budget must fail, not hang")
        } catch let error as AgentProcessError {
            guard case .timedOut = error else { return XCTFail("Expected a timeout, got \(error)") }
        }

        let pidText = try String(contentsOfFile: grandchildMarker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(pid_t(pidText))
        try await Self.eventually(timeout: 3, "the grandchild must die with its group") {
            kill(grandchild, 0) != 0
        }
    }

    func testTimeoutEscalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        let path = try writeScript("stubborn-agent", """
        trap '' TERM
        sleep 60
        """)
        let started = Date()
        do {
            _ = try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 1)
            XCTFail("An agent that ignores SIGTERM must still be stopped")
        } catch let error as AgentProcessError {
            guard case .timedOut = error else { return XCTFail("Expected a timeout, got \(error)") }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 1.4, "SIGKILL must come after the 500 ms grace period, not instead of SIGTERM")
        XCTAssertLessThan(elapsed, 8, "The escalation must not wait for the agent to finish on its own")
    }

    func testCancellingTheTaskStopsTheAgent() async throws {
        let path = try writeScript("slow-agent", "sleep 60")
        let task = Task { try await AgentProcess.run(executable: path, arguments: [], stdin: nil, timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError || error is AgentProcessError, "got \(error)")
        }
    }

    func testALargePromptIsWrittenWithoutDeadlockingOnThePipeBuffer() async throws {
        // A real analysis prompt is far larger than a 64 KB pipe buffer; a
        // synchronous stdin write would deadlock against an agent that streams
        // before it finishes reading.
        let path = try writeScript("counting-agent", """
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"started"}}'
        bytes=$(wc -c)
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\\n' "$bytes"
        """)
        let big = String(repeating: "x", count: 400_000)
        let provider = CodexAgentProvider(executablePath: path, timeout: 30)
        let response = try await provider.complete(
            AIRequest(messages: [ChatMessage(role: .user, content: big)], model: "gpt-5.6")
        )
        let reported = response.text.split(separator: "\n").last.map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 } ?? 0
        XCTAssertGreaterThanOrEqual(reported, 400_000, "The whole prompt must reach the agent")
    }

    // MARK: - Claude Code CLI

    func testClaudeAgentProviderStreamsDeltasAndPrefersTheFinalResult() async throws {
        let path = try writeScript("claude", """
        cat > /dev/null
        printf '%s\\n' '{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-sonnet-5"}}}'
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"AGENT"}}}'
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"_OK"}}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"AGENT_OK","usage":{"input_tokens":9,"output_tokens":4}}'
        """)
        var chunks: [String] = []
        let provider = ClaudeAgentProvider(executablePath: path, timeout: 20)
        let response = try await provider.stream(
            AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "claude-sonnet-5", reasoningEffort: "low")
        ) { chunks.append($0) }

        XCTAssertEqual(chunks, ["AGENT", "_OK"])
        XCTAssertEqual(response.text, "AGENT_OK")
        XCTAssertEqual(response.model, "claude-sonnet-5")
        XCTAssertEqual(response.usage, AIUsage(inputTokens: 9, outputTokens: 4))
    }

    func testClaudeAgentReportsAnErrorResultRatherThanReturningIt() async throws {
        let path = try writeScript("claude-error", """
        cat > /dev/null
        printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Credit balance is too low"}'
        """)
        let provider = ClaudeAgentProvider(executablePath: path, timeout: 20)
        do {
            _ = try await provider.complete(AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "claude-sonnet-5"))
            XCTFail("An error result must not be rendered as an answer")
        } catch let error as AIProviderError {
            XCTAssertTrue(error.errorDescription?.contains("Credit balance is too low") == true, "got: \(error)")
        }
    }

    // MARK: - ACP (Kiro, OpenCode)

    /// A stub agent that speaks enough ACP to answer one prompt, echoing back
    /// whichever request id it was sent so the test does not depend on the
    /// client's id numbering.
    private func writeACPStub(name: String, offersModelOption: Bool) throws -> String {
        let optionsSink = scratch.appendingPathComponent("\(name)-config.txt").path
        let denialSink = scratch.appendingPathComponent("\(name)-denial.txt").path
        let configOptions = offersModelOption
            ? ",\"configOptions\":[{\"id\":\"model\",\"type\":\"select\",\"currentValue\":\"default\"}]"
            : ""
        return try writeScript(name, """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":[ ]*\\([0-9][0-9]*\\).*/\\1/p')
          case "$line" in
            *'"id":99'*)
              # The client's answer to the write request. Recording it before
              # finishing the turn is what makes the refusal observable
              # instead of a race against process teardown.
              printf '%s\\n' "$line" >> \(denialSink)
              printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"AGENT"}}}}'
              printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"_OK"}}}}'
              printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\\n' "$promptid" ;;
            *'"method":"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\\n' "$id" ;;
            *'"method":"session/new"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"stub-session"\(configOptions)}}\\n' "$id" ;;
            *'"method":"session/set_config_option"'*)
              printf '%s\\n' "$line" >> \(optionsSink)
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
            *'"method":"session/prompt"'*)
              promptid="$id"
              printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}'
              printf '%s\\n' '{"jsonrpc":"2.0","id":99,"method":"fs/write_text_file","params":{"path":"/etc/passwd","content":"nope"}}' ;;
          esac
        done
        """)
    }

    func testKiroStyleACPProviderCompletesAPromptAndStreamsChunks() async throws {
        let path = try writeACPStub(name: "kiro-cli", offersModelOption: false)
        var chunks: [String] = []
        let provider = ACPAgentProvider.kiro(executablePath: path, timeout: 20)
        let response = try await provider.stream(
            AIRequest(messages: [ChatMessage(role: .user, content: "Say AGENT_OK")], model: "auto", reasoningEffort: "high")
        ) { chunks.append($0) }

        XCTAssertEqual(chunks, ["AGENT", "_OK"], "Only agent message chunks are text; thoughts are not the answer")
        XCTAssertEqual(response.text, "AGENT_OK")
        XCTAssertNil(response.usage, "ACP carries no usage numbers and none may be invented")
    }

    func testKiroPassesModelAndEffortOnTheCommandLine() {
        let provider = ACPAgentProvider.kiro(executablePath: "/bin/true")
        XCTAssertEqual(provider.arguments(model: "auto", effort: "xhigh"), ["acp", "--model", "auto", "--effort", "xhigh"])
    }

    func testOpenCodeSetsItsModelOverTheProtocolAndStillAnswers() async throws {
        let path = try writeACPStub(name: "opencode", offersModelOption: true)
        let provider = ACPAgentProvider.openCode(executablePath: path, timeout: 20)

        XCTAssertEqual(provider.arguments(model: "anthropic/claude-sonnet-5", effort: "high"), ["acp"],
                       "OpenCode's acp subcommand takes no model flag")

        let response = try await provider.complete(
            AIRequest(messages: [ChatMessage(role: .user, content: "Say AGENT_OK")], model: "anthropic/claude-sonnet-5")
        )
        XCTAssertEqual(response.text, "AGENT_OK")

        let sent = try String(contentsOfFile: scratch.appendingPathComponent("opencode-config.txt").path, encoding: .utf8)
        XCTAssertTrue(sent.contains("session/set_config_option"), sent)
        XCTAssertTrue(sent.contains("anthropic/claude-sonnet-5"), sent)
    }

    func testACPProviderRefusesAnAgentsFilesystemWriteRequest() async throws {
        // The stub asks to write /etc/passwd mid-prompt. The run must still
        // complete, and a refusal must be what goes back on the wire —
        // Reviewrr advertises no filesystem capability (ADR-0004).
        let path = try writeACPStub(name: "grabby-agent", offersModelOption: false)
        let provider = ACPAgentProvider.kiro(executablePath: path, timeout: 20)
        let response = try await provider.complete(
            AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "auto")
        )
        XCTAssertEqual(response.text, "AGENT_OK", "A denied tool request must not abort the answer")

        let reply = try String(contentsOfFile: scratch.appendingPathComponent("grabby-agent-denial.txt").path, encoding: .utf8)
        XCTAssertTrue(reply.contains("-32601"), "Expected a method-not-found refusal, got: \(reply)")
        XCTAssertFalse(reply.contains("\"result\""), "A write request must never be answered with a success result")
    }

    func testACPPermissionRequestIsRefusedPerCallWhenTheAgentOffersThatOption() {
        let refusal = ACPClient.refusal(for: [
            "options": [
                ["optionId": "allow-1", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject-1", "name": "Reject", "kind": "reject_once"],
            ],
        ])
        XCTAssertEqual(refusal["outcome"] as? String, "selected")
        XCTAssertEqual(
            refusal["optionId"] as? String, "reject-1",
            "Rejecting one call keeps the turn alive; cancelling would throw away the answer"
        )
    }

    func testACPPermissionRequestFallsBackToCancellingWhenNoRejectOptionIsOffered() {
        XCTAssertEqual(ACPClient.refusal(for: nil)["outcome"] as? String, "cancelled")
        let onlyAllow: [String: Any] = ["options": [["optionId": "allow-1", "kind": "allow_always"]]]
        XCTAssertEqual(ACPClient.refusal(for: onlyAllow)["outcome"] as? String, "cancelled")
    }

    func testACPProviderFailsClearlyWhenTheAgentExitsBeforeAnswering() async throws {
        let path = try writeScript("acp-dies", """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              echo 'not authenticated' >&2
              exit 1 ;;
          esac
        done
        """)
        let provider = ACPAgentProvider.kiro(executablePath: path, timeout: 20)
        do {
            _ = try await provider.complete(AIRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "auto"))
            XCTFail("An agent that dies during the handshake must fail the request")
        } catch let error as AIProviderError {
            XCTAssertTrue(error.errorDescription?.contains("exited before answering") == true, "got: \(error)")
        }
    }

    // MARK: - Availability

    func testAvailabilityProbeReadsAVersionFromARealBinary() async throws {
        let path = try writeScript("fake-tool", "echo 'fake-tool 9.9.9'")
        setenv("REVIEWRR_TEST_BIN", path, 1)
        defer { unsetenv("REVIEWRR_TEST_BIN") }

        let spec = AgentBinarySpec(
            providerID: "test-agent", commandName: "fake-tool",
            overrideEnvVar: "REVIEWRR_TEST_BIN", versionArguments: ["--version"]
        )
        let availability = await AgentAvailabilityProbe.shared.availability(for: spec, refresh: true)
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "fake-tool 9.9.9")
        XCTAssertEqual(availability.path, path)
    }

    func testAvailabilityProbeNamesTheEnvironmentVariableWhenTheBinaryIsMissing() async {
        let spec = AgentBinarySpec(
            providerID: "absent-agent", commandName: "definitely-not-installed-\(UUID().uuidString)",
            overrideEnvVar: "ABSENT_BIN", versionArguments: ["--version"]
        )
        let availability = await AgentAvailabilityProbe.shared.availability(for: spec, refresh: true)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.failureReason?.contains("ABSENT_BIN") == true, availability.failureReason ?? "")
    }

    func testAvailabilityProbeReportsABinaryThatCannotRun() async throws {
        let path = try writeScript("broken-tool", "echo 'boom' >&2; exit 127")
        setenv("REVIEWRR_BROKEN_BIN", path, 1)
        defer { unsetenv("REVIEWRR_BROKEN_BIN") }
        let spec = AgentBinarySpec(
            providerID: "broken-agent", commandName: "broken-tool",
            overrideEnvVar: "REVIEWRR_BROKEN_BIN", versionArguments: ["--version"]
        )
        let availability = await AgentAvailabilityProbe.shared.availability(for: spec, refresh: true)
        XCTAssertFalse(availability.isAvailable, "An installed but broken binary is not usable")
        XCTAssertTrue(availability.failureReason?.contains("127") == true, availability.failureReason ?? "")
    }

    func testAvailabilityIsCachedSoOpeningSettingsDoesNotRespawnTheProbe() async throws {
        let counter = scratch.appendingPathComponent("probe-count.txt").path
        let path = try writeScript("counted-tool", """
        echo x >> \(counter)
        echo 'counted-tool 1.0'
        """)
        setenv("REVIEWRR_COUNTED_BIN", path, 1)
        defer { unsetenv("REVIEWRR_COUNTED_BIN") }
        let spec = AgentBinarySpec(
            providerID: "counted-agent", commandName: "counted-tool",
            overrideEnvVar: "REVIEWRR_COUNTED_BIN", versionArguments: ["--version"]
        )
        _ = await AgentAvailabilityProbe.shared.availability(for: spec, refresh: true)
        _ = await AgentAvailabilityProbe.shared.availability(for: spec)
        _ = await AgentAvailabilityProbe.shared.availability(for: spec)
        let runs = try String(contentsOfFile: counter, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1, "Three asks must cost one spawn")
    }

    func testBinaryOverrideWinsOverPathAndIsNotBackfilledWhenWrong() throws {
        let path = try writeScript("codex", "echo hi")
        setenv("CODEX_BIN", path, 1)
        XCTAssertEqual(AgentEnvironment.resolvePath(for: .codex), path)

        setenv("CODEX_BIN", "/nowhere/codex", 1)
        XCTAssertNil(
            AgentEnvironment.resolvePath(for: .codex),
            "A wrong CODEX_BIN must be reported, not silently replaced by whatever is on PATH"
        )
        unsetenv("CODEX_BIN")
    }

    func testSearchPathCoversTheInstallRootsAGUILaunchWouldMiss() {
        let directories = AgentEnvironment.searchDirectories()
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(directories.contains("/usr/local/bin"))
        XCTAssertEqual(Set(directories).count, directories.count, "Duplicated PATH entries slow every lookup")
    }

    /// The budget is now an *idle* one — how long an agent may stay silent —
    /// and the environment variable still overrides it. The fallback is the
    /// value in Settings rather than a hard-coded constant, so this asserts
    /// the behaviour (a bad value never leaves the run with no budget) rather
    /// than the number, which the reviewer can change.
    func testIdleBudgetComesFromAIAgentTimeoutMSAndFallsBackToTheSetting() {
        setenv("AI_AGENT_TIMEOUT_MS", "4500", 1)
        XCTAssertEqual(AgentEnvironment.idleTimeout, 4.5, accuracy: 0.001)
        XCTAssertEqual(AgentEnvironment.defaultTimeout, 4.5, accuracy: 0.001)

        setenv("AI_AGENT_TIMEOUT_MS", "not-a-number", 1)
        XCTAssertEqual(
            AgentEnvironment.idleTimeout, AppSettings.load().aiAgentIdleTimeoutSeconds,
            "A malformed budget falls back rather than failing every run"
        )
        XCTAssertGreaterThan(AgentEnvironment.idleTimeout, 0)
        unsetenv("AI_AGENT_TIMEOUT_MS")
    }

    /// Silence is the failure signal; total run time is only a backstop.
    func testMaximumRuntimeIsFarLargerThanTheIdleBudget() {
        XCTAssertGreaterThan(AgentEnvironment.maximumRuntime, AgentEnvironment.idleTimeout * 5)
    }

    // MARK: - Registry and prompt shaping

    func testEveryLocalAgentDescriptorNamesABinaryAndNeedsNoKey() {
        let agents = AIProviderRegistry.all.filter { $0.localAgent != nil }
        XCTAssertEqual(Set(agents.map(\.id)), ["codex", "claude-agent", "kiro", "opencode"])
        for descriptor in agents {
            XCTAssertFalse(descriptor.needsAPIKey, "\(descriptor.id) must not ask for a key it never sends")
            XCTAssertFalse(descriptor.needsBaseURL)
            XCTAssertNotNil(AgentBinarySpec.spec(for: descriptor.id))
        }
    }

    func testCodexOffersTheAgreedModelsAndEfforts() {
        XCTAssertEqual(AIProviderRegistry.codex.models.map(\.modelID), ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6"])
        XCTAssertEqual(AIProviderRegistry.codex.efforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(AIProviderRegistry.codex.defaultModel, "gpt-5.6-sol")
    }

    func testUnknownEffortCollapsesToMediumRatherThanFailingTheRun() {
        XCTAssertEqual(AgentEffort.normalized("XHIGH"), "xhigh")
        XCTAssertEqual(AgentEffort.normalized("thorough"), "medium")
        XCTAssertEqual(AgentEffort.normalized(nil), "medium")
        XCTAssertEqual(AgentEffort.normalized(""), "medium")
    }

    func testJSONModeRestatesTheContractForAgentsThatHaveNoJSONFlag() {
        let prompt = AgentPrompt.flatten(
            AIRequest(system: "Analyse.", messages: [ChatMessage(role: .user, content: "Go")], model: "m", jsonMode: true)
        )
        XCTAssertTrue(prompt.hasPrefix("Analyse."))
        XCTAssertTrue(prompt.contains("User:\nGo"))
        XCTAssertTrue(prompt.hasSuffix("Respond with exactly one JSON object and no other text, Markdown, or code fence."))
    }

    @MainActor
    func testMissingAgentIsReportedAsAMissingBinaryNotAMissingKey() {
        setenv("CODEX_BIN", "/nowhere/codex", 1)
        defer { unsetenv("CODEX_BIN") }
        let error = AIModel.notConfiguredError(providerID: "codex")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("CODEX_BIN"), description)
        XCTAssertFalse(description.contains("API key"), description)
    }

    // MARK: - Helpers

    private static func eventually(
        timeout: TimeInterval, _ message: String, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message, file: file, line: line)
    }
}

/// Opt-in runs against the CLIs actually installed on this machine.
///
/// Off by default: they cost model tokens, need the reviewer's own agent
/// credentials, and fail for reasons that are not Reviewrr's (a monthly usage
/// limit, an expired login). Enable them with
///
/// ```
/// TEST_RUNNER_REVIEWRR_LIVE_AGENT_TESTS=1 make test
/// ```
///
/// The `TEST_RUNNER_` prefix is how `xcodebuild` forwards a variable into the
/// test process; without it the value never leaves the shell. That matters for
/// more than the switch: the test runner does not inherit the shell
/// environment at all, so an agent that reads a credential from one (OpenCode
/// picks up `GEMINI_API_KEY`) sees nothing here and behaves differently than
/// it does in a terminal. Forward what the agent needs the same way.
final class LiveAgentProviderTests: XCTestCase {
    private func skipUnlessEnabled() throws {
        guard ProcessInfo.processInfo.environment["REVIEWRR_LIVE_AGENT_TESTS"] == "1" else {
            throw XCTSkip("Set REVIEWRR_LIVE_AGENT_TESTS=1 to run against the installed agent CLIs.")
        }
    }

    /// An agent that reaches its provider and is told "no" has proved the
    /// transport; the account's state is not something this suite can fix, so
    /// it skips rather than reporting a red test the reader cannot act on. A
    /// timeout is never skipped — that is the failure mode this suite exists
    /// to catch.
    private func skipIfProviderRefused(_ error: Error) throws -> Never {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let environmental = [
            "usage limit", "authentication required", "credit balance",
            "rate limit", "not logged in", "quota",
        ]
        if environmental.contains(where: { message.lowercased().contains($0) }) {
            throw XCTSkip("The agent answered, but its account cannot serve a request: \(message)")
        }
        XCTFail(message)
        throw error
    }

    private func path(for spec: AgentBinarySpec) throws -> String {
        guard let path = AgentEnvironment.resolvePath(for: spec) else {
            throw XCTSkip("\(spec.commandName) is not installed on this machine.")
        }
        return path
    }

    func testCodexAnswersAOneWordPrompt() async throws {
        try skipUnlessEnabled()
        let provider = CodexAgentProvider(executablePath: try path(for: .codex), timeout: 180)
        let response = try await provider.complete(AIRequest(
            messages: [ChatMessage(role: .user, content: "Reply with exactly: AGENT_OK")],
            model: "gpt-5.6-sol", reasoningEffort: "low"
        ))
        XCTAssertTrue(response.text.contains("AGENT_OK"), response.text)
        XCTAssertGreaterThan(response.elapsedMS, 0)
    }

    func testClaudeCodeAnswersAOneWordPrompt() async throws {
        try skipUnlessEnabled()
        let provider = ClaudeAgentProvider(executablePath: try path(for: .claudeAgent), timeout: 180)
        let response = try await provider.complete(AIRequest(
            messages: [ChatMessage(role: .user, content: "Reply with exactly: AGENT_OK")],
            model: "claude-haiku-4-5-20251001", reasoningEffort: "low"
        ))
        XCTAssertTrue(response.text.contains("AGENT_OK"), response.text)
    }

    func testKiroAnswersOverACP() async throws {
        try skipUnlessEnabled()
        let provider = ACPAgentProvider.kiro(executablePath: try path(for: .kiro), timeout: 180)
        do {
            let response = try await provider.complete(AIRequest(
                messages: [ChatMessage(role: .user, content: "Reply with exactly: AGENT_OK")],
                model: "", reasoningEffort: "low"
            ))
            XCTAssertTrue(response.text.contains("AGENT_OK"), response.text)
        } catch {
            try skipIfProviderRefused(error)
        }
    }

    func testOpenCodeAnswersOverACP() async throws {
        try skipUnlessEnabled()
        // OpenCode needs to be told which model to use, and the runner has
        // none of the shell's credentials, so an unauthenticated model here
        // does not fail fast — it produces nothing until the budget runs out.
        // Naming the model is therefore required rather than defaulted, and
        // it also exercises `session/set_config_option`, the part of this
        // provider the stub suite cannot prove against the real agent.
        guard let model = ProcessInfo.processInfo.environment["REVIEWRR_OPENCODE_MODEL"] else {
            throw XCTSkip(
                "Set TEST_RUNNER_REVIEWRR_OPENCODE_MODEL to a model this OpenCode install can serve "
                    + "(see `opencode models`), plus TEST_RUNNER_ for any credential it reads from the environment."
            )
        }
        let provider = ACPAgentProvider.openCode(executablePath: try path(for: .openCode), timeout: 240)
        do {
            let response = try await provider.complete(AIRequest(
                messages: [ChatMessage(role: .user, content: "Reply with exactly: AGENT_OK")],
                model: model, reasoningEffort: "low"
            ))
            XCTAssertTrue(response.text.contains("AGENT_OK"), response.text)
        } catch {
            try skipIfProviderRefused(error)
        }
    }
}
