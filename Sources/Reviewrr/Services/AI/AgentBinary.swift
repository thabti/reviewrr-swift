import Foundation
import os

/// Where a local agent CLI lives and how to ask it whether it works.
struct AgentBinarySpec: Equatable {
    /// The `AIProviderDescriptor.id` this binary backs.
    var providerID: String
    /// Command name looked up on PATH when the override is unset.
    var commandName: String
    /// Environment variable holding an absolute path that wins over PATH.
    var overrideEnvVar: String
    /// Arguments that make the binary print a version and exit quickly.
    var versionArguments: [String]

    static let codex = AgentBinarySpec(
        providerID: "codex", commandName: "codex", overrideEnvVar: "CODEX_BIN", versionArguments: ["--version"]
    )
    static let claudeAgent = AgentBinarySpec(
        providerID: "claude-agent", commandName: "claude", overrideEnvVar: "CLAUDE_BIN", versionArguments: ["--version"]
    )
    static let kiro = AgentBinarySpec(
        providerID: "kiro", commandName: "kiro-cli", overrideEnvVar: "KIRO_BIN", versionArguments: ["--version"]
    )
    static let openCode = AgentBinarySpec(
        providerID: "opencode", commandName: "opencode", overrideEnvVar: "OPENCODE_BIN", versionArguments: ["--version"]
    )

    static let all: [AgentBinarySpec] = [codex, claudeAgent, kiro, openCode]

    static func spec(for providerID: String) -> AgentBinarySpec? {
        all.first { $0.providerID == providerID }
    }
}

/// Environment handed to every spawned agent, plus the two knobs the goal
/// fixes: `AI_AGENT_TIMEOUT_MS` for the request budget and `<TOOL>_BIN` for
/// the binary path.
enum AgentEnvironment {
    static let fallbackTimeout: TimeInterval = 120

    /// How long the agent may stay *silent* before the run is abandoned.
    ///
    /// This is an idle budget, not a total one. Analysing a large pull
    /// request through a command-line agent legitimately takes minutes, and a
    /// wall-clock cap killed healthy runs mid-answer — the reviewer saw
    /// "codex did not answer within 120s" while codex was busy answering.
    /// What actually indicates a broken run is silence: no output at all for
    /// this long.
    ///
    /// `AI_AGENT_TIMEOUT_MS` still wins when set, and is read fresh each time
    /// so it can be changed without relaunching from a new shell.
    static var idleTimeout: TimeInterval {
        if
            let raw = ProcessInfo.processInfo.environment["AI_AGENT_TIMEOUT_MS"],
            let milliseconds = Double(raw.trimmingCharacters(in: .whitespaces)),
            milliseconds > 0
        {
            return milliseconds / 1000
        }
        let configured = AppSettings.load().aiAgentIdleTimeoutSeconds
        return configured > 0 ? configured : fallbackTimeout
    }

    /// Retained so existing callers keep compiling; it is the idle budget.
    static var defaultTimeout: TimeInterval { idleTimeout }

    /// A backstop for an agent that keeps chattering but never finishes.
    /// Silence is the useful signal; this only stops a run that has gone on
    /// long past any plausible analysis.
    static var maximumRuntime: TimeInterval {
        if
            let raw = ProcessInfo.processInfo.environment["AI_AGENT_MAX_RUNTIME_MS"],
            let milliseconds = Double(raw.trimmingCharacters(in: .whitespaces)),
            milliseconds > 0
        {
            return milliseconds / 1000
        }
        return 30 * 60
    }

    /// Directories appended to PATH before looking for an agent.
    ///
    /// A GUI-launched macOS app inherits `launchd`'s PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not the reviewer's shell PATH, so
    /// every Homebrew/npm/bun install of these tools would be invisible.
    /// Adding the standard install roots is what makes "it works in my
    /// terminal" also true in the app.
    static func searchDirectories() -> [String] {
        let home = NSHomeDirectory()
        let shellPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let inherited = shellPath.split(separator: ":").map(String.init)
        let common = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.n/bin", "\(home)/.cargo/bin",
            "\(home)/.claude/local",
        ]
        var seen = Set<String>()
        return (inherited + common).filter { seen.insert($0).inserted }
    }

    /// The child's environment: the app's own, with PATH widened to the
    /// search roots. Agent CLIs read their credentials from `HOME`
    /// (`~/.codex`, `~/.claude`, `~/.local/share/opencode`), so the parent
    /// environment is inherited rather than replaced — Reviewrr never holds
    /// or forwards a key for these providers.
    static func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchDirectories().joined(separator: ":")
        // Agent CLIs colour and animate for a TTY; ours is a pipe, and a
        // spinner in the middle of JSONL would break every parser here.
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Resolves a spec to an executable path without running anything.
    ///
    /// Memoized, because this walks the filesystem and the AI panel asks for
    /// it *while building its view*: `AIPanelView.init` seeds its
    /// "is the provider configured" state from here, the inspector rebuilds
    /// that view whenever the root view's body runs, and stepping through
    /// files with `j` then spent 6% of the main thread inside
    /// `isExecutableFile` — around a dozen `stat` calls per keystroke, to
    /// answer a question whose answer changes when someone installs a CLI.
    ///
    /// The TTL matches `AgentAvailabilityProbe`: installing the tool and
    /// coming back works without a relaunch.
    static func resolvePath(for spec: AgentBinarySpec) -> String? {
        // Keyed on the environment the answer was computed in, not just the
        // spec: an override or a `PATH` that changed makes the memo wrong,
        // not merely stale. Two `getenv` reads, deliberately not
        // `ProcessInfo.environment`, which allocates the whole dictionary.
        let key = cacheKey(for: spec)
        if let hit = pathCache.withLock({ cache -> CachedPath? in
            guard let entry = cache[key], Date().timeIntervalSince(entry.resolvedAt) < pathCacheTTL
            else { return nil }
            return entry
        }) {
            return hit.path
        }
        let resolved = resolvePathUncached(for: spec)
        pathCache.withLock { $0[key] = CachedPath(path: resolved, resolvedAt: Date()) }
        return resolved
    }

    private static func cacheKey(for spec: AgentBinarySpec) -> String {
        "\(spec.providerID)\n\(rawEnvironment(spec.overrideEnvVar) ?? "")\n\(rawEnvironment("PATH") ?? "")"
    }

    private static func rawEnvironment(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    /// Drops the memoized paths — call after the reviewer changes an override
    /// or installs a tool, so the next lookup goes back to the filesystem.
    static func invalidateResolvedPaths() {
        pathCache.withLock { $0.removeAll() }
    }

    private struct CachedPath {
        let path: String?
        let resolvedAt: Date
    }

    private static let pathCacheTTL: TimeInterval = 300
    private static let pathCache = OSAllocatedUnfairLock(initialState: [String: CachedPath]())

    private static func resolvePathUncached(for spec: AgentBinarySpec) -> String? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[spec.overrideEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            // An explicit override that does not exist is a configuration
            // error worth surfacing, so it is not silently backfilled from
            // PATH.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        for directory in searchDirectories() {
            let candidate = (directory as NSString).appendingPathComponent(spec.commandName)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Whether a local agent is installed, cached so the picker can grey out a
/// missing tool instead of every request discovering it the hard way.
struct AgentAvailability: Equatable {
    var providerID: String
    var path: String?
    var version: String?
    var failureReason: String?
    var checkedAt: Date

    var isAvailable: Bool { path != nil && failureReason == nil }
}

/// Probes each agent binary at most once per TTL.
///
/// An actor because the AI panel, Settings, and an in-flight analysis all ask
/// at once on first open; without serialisation that is three `--version`
/// spawns for the same answer.
actor AgentAvailabilityProbe {
    static let shared = AgentAvailabilityProbe()

    /// Long enough that opening Settings twice costs one probe, short enough
    /// that installing the tool and coming back works without a relaunch.
    private let ttl: TimeInterval = 300
    private var cache: [String: AgentAvailability] = [:]
    private var inFlight: [String: Task<AgentAvailability, Never>] = [:]

    /// Cached answer only — for synchronous UI that must not spawn anything.
    func cached(_ providerID: String) -> AgentAvailability? {
        guard let entry = cache[providerID], Date().timeIntervalSince(entry.checkedAt) < ttl else { return nil }
        return entry
    }

    func availability(for spec: AgentBinarySpec, refresh: Bool = false) async -> AgentAvailability {
        if !refresh, let entry = cached(spec.providerID) { return entry }
        if let existing = inFlight[spec.providerID] { return await existing.value }

        let task = Task<AgentAvailability, Never> { await Self.probe(spec) }
        inFlight[spec.providerID] = task
        let result = await task.value
        inFlight[spec.providerID] = nil
        cache[spec.providerID] = result
        return result
    }

    func invalidate() {
        cache.removeAll()
    }

    private static func probe(_ spec: AgentBinarySpec) async -> AgentAvailability {
        guard let path = AgentEnvironment.resolvePath(for: spec) else {
            return AgentAvailability(
                providerID: spec.providerID, path: nil, version: nil,
                failureReason: AgentProcessError.binaryNotFound(name: spec.commandName, envVar: spec.overrideEnvVar).errorDescription,
                checkedAt: Date()
            )
        }
        do {
            // A short budget on purpose: `--version` that hangs means a broken
            // install, and the picker should say so rather than stall.
            let output = try await AgentProcess.run(
                executable: path, arguments: spec.versionArguments, stdin: nil, timeout: 15
            )
            guard output.exitCode == 0 else {
                return AgentAvailability(
                    providerID: spec.providerID, path: path, version: nil,
                    failureReason: AgentProcessError.exited(
                        binary: spec.commandName, code: output.exitCode, stderr: output.stderr
                    ).errorDescription,
                    checkedAt: Date()
                )
            }
            let version = output.stdoutLines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return AgentAvailability(
                providerID: spec.providerID, path: path,
                version: version?.trimmingCharacters(in: .whitespacesAndNewlines),
                failureReason: nil, checkedAt: Date()
            )
        } catch {
            return AgentAvailability(
                providerID: spec.providerID, path: path, version: nil,
                failureReason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                checkedAt: Date()
            )
        }
    }
}
