import Foundation

/// Runs dashboard polling entirely in-process, matching the product rule
/// that Reviewrr never syncs while the app isn't running: nothing here
/// survives past `stop()` — no daemon, no background service, no leaked
/// timer. One `Task` per watched project (plus one for the cross-repo
/// reviewer buckets) loops sleep-refresh-sleep for as long as it isn't
/// cancelled.
@MainActor
final class PollingCoordinator {
    typealias RefreshProject = (WatchedProject) async -> Bool
    typealias RefreshBuckets = () async -> Bool

    private var projectTasks: [String: Task<Void, Never>] = [:]
    private var bucketsTask: Task<Void, Never>?
    /// Per-project exponential backoff state, reset on the next success.
    private var backoffSeconds: [String: TimeInterval] = [:]
    private var bucketsBackoffSeconds: TimeInterval?

    /// Starts (or restarts) polling for the given projects. Safe to call
    /// repeatedly — always tears down any previous run first, so changing
    /// the watchlist mid-session just means calling `start` again.
    func start(
        projects: () -> [WatchedProject],
        settings: @escaping () -> AppSettings,
        refreshProject: @escaping RefreshProject,
        refreshBuckets: @escaping RefreshBuckets
    ) {
        stop()
        guard settings().pollingEnabled else { return }
        for project in projects() where !project.isMuted {
            scheduleProject(project, settings: settings, refreshProject: refreshProject)
        }
        scheduleBuckets(settings: settings, refreshBuckets: refreshBuckets)
    }

    func stop() {
        for task in projectTasks.values { task.cancel() }
        projectTasks.removeAll()
        bucketsTask?.cancel()
        bucketsTask = nil
        backoffSeconds.removeAll()
        bucketsBackoffSeconds = nil
    }

    private func scheduleProject(
        _ project: WatchedProject, settings: @escaping () -> AppSettings, refreshProject: @escaping RefreshProject
    ) {
        projectTasks[project.key]?.cancel()
        projectTasks[project.key] = Task { [weak self] in
            // Stagger the *first* sync too, within a small window, so many
            // watched projects don't all hit GitHub in the same instant on
            // launch — "render cached metadata, then stagger refreshes."
            let initialSettings = settings()
            let staggerWindow = TimeInterval(initialSettings.pollIntervalSeconds) * initialSettings.pollJitterFraction
            try? await Task.sleep(for: .seconds(Double.random(in: 0...max(staggerWindow, 1))))

            while !Task.isCancelled {
                let succeeded = await refreshProject(project)
                guard let self else { return }
                let currentSettings = settings()
                let interval = self.nextInterval(
                    key: project.key, succeeded: succeeded, settings: currentSettings, backoff: &self.backoffSeconds
                )
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func scheduleBuckets(settings: @escaping () -> AppSettings, refreshBuckets: @escaping RefreshBuckets) {
        bucketsTask?.cancel()
        bucketsTask = Task { [weak self] in
            while !Task.isCancelled {
                let succeeded = await refreshBuckets()
                guard let self else { return }
                let currentSettings = settings()
                let interval: TimeInterval
                if succeeded {
                    self.bucketsBackoffSeconds = nil
                    interval = Self.jitteredInterval(base: currentSettings.pollIntervalSeconds, jitterFraction: currentSettings.pollJitterFraction)
                } else {
                    let next = Self.nextBackoffInterval(
                        previous: self.bucketsBackoffSeconds ?? TimeInterval(currentSettings.pollIntervalSeconds),
                        base: currentSettings.pollIntervalSeconds, max: currentSettings.maxPollIntervalSeconds
                    )
                    self.bucketsBackoffSeconds = next
                    interval = Self.jitteredInterval(base: Int(next), jitterFraction: currentSettings.pollJitterFraction)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func nextInterval(
        key: String, succeeded: Bool, settings: AppSettings, backoff: inout [String: TimeInterval]
    ) -> TimeInterval {
        if succeeded {
            backoff[key] = nil
            return Self.jitteredInterval(base: settings.pollIntervalSeconds, jitterFraction: settings.pollJitterFraction)
        }
        let next = Self.nextBackoffInterval(
            previous: backoff[key] ?? TimeInterval(settings.pollIntervalSeconds),
            base: settings.pollIntervalSeconds, max: settings.maxPollIntervalSeconds
        )
        backoff[key] = next
        return Self.jitteredInterval(base: Int(next), jitterFraction: settings.pollJitterFraction)
    }

    // MARK: - Pure interval math (unit-tested directly)

    /// Applies ±`jitterFraction` randomization so many projects polling on
    /// the same base interval don't all hit GitHub in the same instant.
    static func jitteredInterval(base: Int, jitterFraction: Double) -> TimeInterval {
        let baseValue = TimeInterval(max(base, 1))
        let clampedFraction = min(max(jitterFraction, 0), 1)
        let jitter = baseValue * clampedFraction
        return baseValue + Double.random(in: -jitter...jitter)
    }

    /// Doubles the previous interval on repeated failure/rate-limiting,
    /// capped at `maxPollIntervalSeconds` — "exponential backoff ... up to
    /// 30 minutes" by default.
    static func nextBackoffInterval(previous: TimeInterval, base: Int, max maxSeconds: Int) -> TimeInterval {
        let start = previous > 0 ? previous : TimeInterval(base)
        return min(start * 2, TimeInterval(maxSeconds))
    }
}
