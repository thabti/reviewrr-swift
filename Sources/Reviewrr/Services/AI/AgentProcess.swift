import Darwin
import Foundation

/// Errors a spawned agent CLI can produce before its output ever reaches a
/// provider adapter. Distinct from `AIProviderError` on purpose: this layer
/// knows about processes, not about models, and the adapters translate.
enum AgentProcessError: LocalizedError, Equatable {
    case binaryNotFound(name: String, envVar: String)
    case spawnFailed(binary: String, code: Int32)
    case timedOut(binary: String, seconds: Double, stderr: String)
    case exited(binary: String, code: Int32, stderr: String)
    case workspaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name, let envVar):
            return "\(name) was not found on PATH. Install it, or set \(envVar) to its full path."
        case .spawnFailed(let binary, let code):
            return "Could not start \(binary) (posix_spawn error \(code))."
        case .timedOut(let binary, let seconds, let stderr):
            // The agent's own last words matter here: "did not answer" alone
            // sends a reviewer looking in the wrong place when the tool was
            // actually printing a login or quota problem to stderr.
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = detail.isEmpty ? "" : " Last output: \(AgentProcess.lastLines(detail, count: 3))"
            return """
                \(binary) produced no output for \(Int(seconds))s, so Reviewrr stopped waiting. Raise "Agent idle timeout" in Settings › AI if it needs longer.\(tail)
                """
        case .exited(let binary, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = detail.isEmpty ? "" : " \(AgentProcess.lastLines(detail, count: 3))"
            return "\(binary) exited with code \(code).\(tail)"
        case .workspaceFailed(let message):
            return "Could not create a temporary working directory for the agent: \(message)"
        }
    }
}

/// A disposable working directory handed to a local agent as its cwd.
///
/// Agent CLIs treat their cwd as the project they may read. Pointing them at
/// an empty directory under `TMPDIR` — never the reviewer's checkout — means a
/// misbehaving agent finds nothing of the user's to read, and the directory
/// disappears with the request. This is a blast-radius reduction, not a
/// sandbox: see `ADR-0004`'s security statement.
struct AgentWorkspace {
    let url: URL

    static func makeEphemeral() throws -> AgentWorkspace {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reviewrr-agent-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AgentProcessError.workspaceFailed(error.localizedDescription)
        }
        return AgentWorkspace(url: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A live child process speaking newline-delimited text on stdio.
///
/// Spawned with `POSIX_SPAWN_SETPGROUP` so the child leads its own process
/// group: agent CLIs fan out into model workers and shells, and signalling
/// the group (`kill(-pgid, …)`) is the only way to take the whole tree down.
/// Reviewrr is not sandboxed (see `project.yml`), so an orphaned tree would
/// otherwise outlive the app.
final class AgentProcessSession {
    let workingDirectory: URL

    private let lock = NSLock()
    private var pid: pid_t = -1
    private var stdinFD: Int32 = -1
    private var hasExited = false
    private var exitCode: Int32 = -1
    private var stderrBuffer = Data()
    private var lastOutputAt = Date()
    private var stdinClosed = false

    /// stdin writes and the close are ordered on one queue: without that,
    /// a write thread could reach `write()` after `terminate()` closed the
    /// descriptor and the number had been recycled by another file.
    private let stdinQueue = DispatchQueue(label: "com.sabeur.reviewrr.agent-stdin")

    /// Every line the child wrote to stdout, in order, ending when stdout
    /// closes. Consumed once; a second iteration sees nothing.
    private(set) var stdoutLines: AsyncStream<String>!

    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    private init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Launch

    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL
    ) throws -> AgentProcessSession {
        // The child chdirs into the ephemeral workspace before `exec`, so a
        // relative executable path would resolve against that empty directory.
        let executable = executable.hasPrefix("/")
            ? executable
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(executable)
        let session = AgentProcessSession(workingDirectory: workingDirectory)

        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw AgentProcessError.spawnFailed(binary: executable, code: errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, inPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        // `_np` spelling deliberately: the unsuffixed name only exists on
        // much newer SDKs, and the deployment target here is macOS 14.
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Hand the child a clean signal state. Swift's runtime and libdispatch
        // ignore SIGPIPE and block signals on their threads, and `posix_spawn`
        // would pass that mask and those dispositions straight through: an
        // agent that waits on a signal then hangs forever with no output. This
        // is what `/bin/sh` does implicitly for its children, and it is why
        // wrapping the same command in a shell script "fixed" it.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        // Own process group, so the timeout can signal the whole tree.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var childPID: pid_t = -1
        let spawnResult = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { envPointers in
                posix_spawn(&childPID, executable, &fileActions, &attributes, argvPointers, envPointers)
            }
        }

        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])

        guard spawnResult == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            close(errPipe[0])
            throw AgentProcessError.spawnFailed(binary: executable, code: spawnResult)
        }

        session.pid = childPID
        session.stdinFD = inPipe[1]
        var continuation: AsyncStream<String>.Continuation!
        session.stdoutLines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        session.startStdoutReader(fd: outPipe[0], continuation: continuation)
        session.startStderrReader(fd: errPipe[0])
        session.startReaper()
        return session
    }

    // MARK: - Readers

    private func startStdoutReader(fd: Int32, continuation: AsyncStream<String>.Continuation) {
        Thread.detachNewThread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                self.lock.locked { self.lastOutputAt = Date() }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    continuation.yield(String(decoding: lineData, as: UTF8.self))
                }
            }
            if !pending.isEmpty {
                continuation.yield(String(decoding: pending, as: UTF8.self))
            }
            close(fd)
            continuation.finish()
        }
    }

    private func startStderrReader(fd: Int32) {
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                guard let self else { continue }
                self.lock.locked {
                    // Bounded: a chatty agent must not grow this without limit,
                    // and only the tail is ever shown in an error.
                    self.lastOutputAt = Date()
                    self.stderrBuffer.append(contentsOf: buffer[0..<count])
                    if self.stderrBuffer.count > 64 * 1024 {
                        self.stderrBuffer.removeFirst(self.stderrBuffer.count - 64 * 1024)
                    }
                }
            }
            close(fd)
        }
    }

    private func startReaper() {
        let childPID = pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0 && errno == EINTR { continue }
            guard let self else { return }
            let waiters: [CheckedContinuation<Int32, Never>] = self.lock.locked {
                self.hasExited = true
                // Signalled children get the shell's 128 + signal encoding, so
                // "killed by SIGKILL" reads as 137 in an error rather than 0.
                if status & 0o177 != 0 {
                    self.exitCode = 128 + (status & 0o177)
                } else {
                    self.exitCode = (status >> 8) & 0xFF
                }
                let pending = self.exitWaiters
                self.exitWaiters = []
                return pending
            }
            for waiter in waiters { waiter.resume(returning: self.exitCode) }
        }
    }

    // MARK: - Writing

    /// Writes off the calling thread: an analysis prompt is far larger than
    /// the 64 KB pipe buffer, so a synchronous write would deadlock against a
    /// child that streams output back before it finishes reading.
    func writeStdin(_ text: String, thenClose: Bool) {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            if thenClose { closeStdin() }
            return
        }
        stdinQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.lock.locked { self.stdinClosed ? -1 : self.stdinFD }
            guard fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    // EPIPE means the agent stopped reading (it already answered
                    // or died); there is nothing useful to do but stop writing.
                    if written <= 0 { break }
                    offset += written
                }
            }
            if thenClose { self.closeOnStdinQueue() }
        }
    }

    func closeStdin() {
        stdinQueue.async { [weak self] in self?.closeOnStdinQueue() }
    }

    private func closeOnStdinQueue() {
        let fd: Int32 = lock.locked {
            guard !stdinClosed, stdinFD >= 0 else { return -1 }
            stdinClosed = true
            let value = stdinFD
            stdinFD = -1
            return value
        }
        if fd >= 0 { close(fd) }
    }

    // MARK: - Lifecycle

    var isRunning: Bool { lock.locked { !hasExited } }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let finished: Int32? = lock.locked {
                if hasExited { return exitCode }
                exitWaiters.append(continuation)
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
    }

    /// SIGTERM to the group, then SIGKILL 500 ms later if the tree is still
    /// alive. Agent CLIs need the grace period to flush a partial answer and
    /// tear down their own children; anything still standing after it is
    /// wedged and gets killed outright.
    func terminate() {
        let group = lock.locked { hasExited ? -1 : pid }
        guard group > 0 else { return }
        closeStdin()
        kill(-group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-group, SIGKILL)
        }
    }

    var outputIdleTime: TimeInterval { lock.locked { Date().timeIntervalSince(lastOutputAt) } }

    func stderrText() -> String {
        lock.locked { String(decoding: stderrBuffer, as: UTF8.self) }
    }
}

// MARK: - One-shot invocation

struct AgentProcessOutput {
    var stdoutLines: [String]
    var stderr: String
    var exitCode: Int32
}

enum AgentProcess {
    /// Runs `executable` to completion in a throwaway directory, feeding
    /// `stdin` and streaming stdout line by line to `onLine`.
    ///
    /// Watches for *silence*. Every line the agent produces pushes the
    /// deadline out; only a run that stops talking — or one that runs past
    /// `maximumRuntime` altogether — is terminated.
    ///
    /// A plain wall-clock budget could not tell "this agent is wedged" from
    /// "this analysis is big", and killed the second case constantly.
    final class IdleWatchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private let started = Date()
        private let idleTimeout: TimeInterval
        private let maximumRuntime: TimeInterval
        private let externalActivityAge: (@Sendable () -> TimeInterval)?
        private var task: Task<Void, Never>?

        init(
            idleTimeout: TimeInterval,
            maximumRuntime: TimeInterval = AgentEnvironment.maximumRuntime,
            externalActivityAge: (@Sendable () -> TimeInterval)? = nil,
            onTimeout: @escaping @Sendable () -> Void
        ) {
            self.idleTimeout = idleTimeout
            self.maximumRuntime = maximumRuntime
            self.externalActivityAge = externalActivityAge
            task = Task { [weak self] in
                // Checked on a slice rather than slept through in one go, so
                // a line arriving late still counts as life.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.hasExpired() {
                        onTimeout()
                        return
                    }
                }
            }
        }

        /// Called for every line of output.
        func touch() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        private func hasExpired() -> Bool {
            lock.lock()
            let idle = Date().timeIntervalSince(lastActivity)
            lock.unlock()
            let observedIdle = min(idle, externalActivityAge?() ?? idle)
            return observedIdle > idleTimeout || Date().timeIntervalSince(started) > maximumRuntime
        }

        func cancel() { task?.cancel() }
    }

    /// Cancelling the calling task, or exceeding the idle budget, signals the whole
    /// process group; either way the temporary directory is removed before
    /// this returns.
    static func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String] = AgentEnvironment.childEnvironment(),
        timeout: TimeInterval = AgentEnvironment.defaultTimeout,
        /// Whether to return every stdout line. A caller that consumes them
        /// through `onLine` — every provider does — passes `false`: a JSONL
        /// analysis run is megabytes, and keeping a second copy of it to hand
        /// back to nobody is pure waste.
        collectStdout: Bool = true,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentProcessOutput {
        let workspace = try AgentWorkspace.makeEphemeral()
        defer { workspace.remove() }

        let session = try AgentProcessSession.launch(
            executable: executable, arguments: arguments,
            environment: environment, workingDirectory: workspace.url
        )
        if let stdin {
            session.writeStdin(stdin, thenClose: true)
        } else {
            session.closeStdin()
        }

        let timedOut = TimeoutFlag()
        let watchdog = IdleWatchdog(idleTimeout: timeout, externalActivityAge: { session.outputIdleTime }) {
            timedOut.set()
            session.terminate()
        }
        defer { watchdog.cancel() }

        var collected: [String] = []
        do {
            try await withTaskCancellationHandler {
                for await line in session.stdoutLines {
                    try Task.checkCancellation()
                    // Output is life: the agent is working, so the clock that
                    // decides whether it has stalled starts over.
                    watchdog.touch()
                    if collectStdout { collected.append(line) }
                    onLine?(line)
                }
                try Task.checkCancellation()
            } onCancel: {
                session.terminate()
            }
        } catch {
            session.terminate()
            _ = await session.waitForExit()
            throw error
        }

        let code = await session.waitForExit()
        if timedOut.isSet {
            throw AgentProcessError.timedOut(
                binary: (executable as NSString).lastPathComponent, seconds: timeout, stderr: session.stderrText()
            )
        }
        try Task.checkCancellation()
        return AgentProcessOutput(stdoutLines: collected, stderr: session.stderrText(), exitCode: code)
    }

    static func lastLines(_ text: String, count: Int) -> String {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " ")
    }
}

/// Tiny lock-free-enough box so the watchdog task and the awaiting task can
/// agree on "this was a timeout, not a normal exit".
final class TimeoutFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.locked { value } }
    func set() { lock.locked { value = true } }
}

// MARK: - Helpers

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

extension NSLock {
    /// Named `locked` rather than `withLock` so this never collides with, or
    /// silently shadows, Foundation's own `NSLocking.withLock`.
    func locked<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
