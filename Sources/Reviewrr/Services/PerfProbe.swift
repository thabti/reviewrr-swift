import Foundation
import QuartzCore

/// Instrumentation for the review workspace's frame budget.
///
/// Scrolling is smooth when the main thread never holds on to a frame for
/// longer than the display's refresh interval. Two things can break that, and
/// this probe measures both:
///
/// * **Work per row.** `count`/`measure` tally how often a view's `body` runs
///   and how long it takes. A row body that costs 0.2ms is fine at 45 rows
///   and a dropped frame at 400.
/// * **Main-thread stalls.** `StallMonitor` watches for the main queue going
///   deaf: a hitch the user actually sees is the main thread busy past the
///   frame deadline, whoever made it busy.
///
/// Off by default and off in every shipped run: `isEnabled` reads one
/// environment variable once, and every entry point returns immediately when
/// it is false, so instrumenting a hot path costs a branch on a `let`.
enum PerfProbe {
    /// `REVIEWRR_PERF=1` in the environment turns the probe on.
    static let isEnabled = ProcessInfo.processInfo.environment["REVIEWRR_PERF"] == "1"

    private static let state = ProbeState()

    /// One `body` evaluation of `name`. Use where the body is cheap enough
    /// that timing it would cost more than the body.
    @inline(__always)
    static func count(_ name: StaticString) {
        guard isEnabled else { return }
        state.record(String(describing: name), nanoseconds: 0)
    }

    /// One evaluation of `name`, timed. Returns the closure's value so it can
    /// wrap an expression rather than needing a statement.
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ work: () -> T) -> T {
        guard isEnabled else { return work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = work()
        state.record(String(describing: name), nanoseconds: DispatchTime.now().uptimeNanoseconds - start)
        return value
    }

    /// Timestamp for a `body` whose cost is measured with `end`. Paired with
    /// `defer` at the top of a `body`, which is the only place that can time
    /// the construction of the view tree the body returns.
    @inline(__always)
    static func begin() -> UInt64 {
        isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    @inline(__always)
    static func end(_ name: StaticString, _ started: UInt64) {
        guard isEnabled else { return }
        state.record(String(describing: name), nanoseconds: DispatchTime.now().uptimeNanoseconds - started)
    }

    /// Names a stretch of interaction so the report can attribute counts to
    /// it — "scroll", "open file", "type in composer".
    static func mark(_ label: String) {
        guard isEnabled else { return }
        state.mark(label)
    }

    /// Everything gathered since the last `reset`, as lines ready to print.
    static func report() -> String {
        guard isEnabled else { return "PerfProbe disabled — run with REVIEWRR_PERF=1" }
        return state.report()
    }

    static func reset() {
        guard isEnabled else { return }
        state.reset()
    }

    /// A line into the same stream as the reports, so a benchmark run reads
    /// in order.
    static func log(_ message: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data(("[perf] " + message + "\n").utf8))
    }

    /// Starts printing a report every `interval` seconds. Called once at
    /// launch; a no-op when the probe is off.
    static func startReporting(every interval: TimeInterval = 5) {
        guard isEnabled else { return }
        // Two things would otherwise make every number a lie. A background
        // app gets its timers coalesced, so the stall monitor reports
        // lateness the app never caused; and an unfocused window renders
        // fewer frames, so the row counts under-report. A benchmark measures
        // the app a reviewer is looking at.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Reviewrr frame-budget benchmark"
        )
        StallMonitor.shared.start()
        state.startReporting(every: interval)
    }

    /// Held for the lifetime of the process: releasing it lets App Nap back in.
    private nonisolated(unsafe) static var activity: NSObjectProtocol?
}

/// Tallies per-name counts and durations.
///
/// A plain lock rather than an actor: `body` runs on the main thread and must
/// not suspend, and the critical section is a dictionary update.
private final class ProbeState {
    private struct Entry {
        var count = 0
        var totalNanoseconds: UInt64 = 0
        var maxNanoseconds: UInt64 = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var label = "launch"
    private var startedAt = Date()
    private var timer: DispatchSourceTimer?

    func record(_ name: String, nanoseconds: UInt64) {
        lock.lock()
        var entry = entries[name] ?? Entry()
        entry.count += 1
        entry.totalNanoseconds += nanoseconds
        entry.maxNanoseconds = max(entry.maxNanoseconds, nanoseconds)
        entries[name] = entry
        lock.unlock()
    }

    func mark(_ newLabel: String) {
        lock.lock()
        label = newLabel
        lock.unlock()
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        startedAt = Date()
        lock.unlock()
        StallMonitor.shared.reset()
    }

    func report() -> String {
        lock.lock()
        let snapshot = entries
        let phase = label
        let elapsed = Date().timeIntervalSince(startedAt)
        lock.unlock()

        guard !snapshot.isEmpty || StallMonitor.shared.hasSamples else {
            return "[perf] \(phase): nothing recorded"
        }
        var lines = ["[perf] \(phase) over \(String(format: "%.1f", elapsed))s"]
        for (name, entry) in snapshot.sorted(by: { $0.value.totalNanoseconds > $1.value.totalNanoseconds }) {
            let total = Double(entry.totalNanoseconds) / 1_000_000
            let mean = entry.count == 0 ? 0 : total / Double(entry.count)
            let peak = Double(entry.maxNanoseconds) / 1_000_000
            lines.append(String(format: "  %-34@ n=%-7d total=%8.2fms mean=%6.3fms max=%6.3fms",
                                name as NSString, entry.count, total, mean, peak))
        }
        lines.append(StallMonitor.shared.summary())
        return lines.joined(separator: "\n")
    }

    func startReporting(every interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(Data((self.report() + "\n").utf8))
        }
        timer.resume()
        self.timer = timer
    }
}

/// Detects the hitches a reviewer actually feels.
///
/// Not timer lateness: an idle Mac coalesces timers to save power, so a 4ms
/// timer on an idle main queue reports 20ms of "stall" that no reviewer would
/// ever see, and the baseline swallows the signal. This measures the main
/// run loop's *busy* interval instead — from the moment it wakes up to the
/// moment it goes back to sleep — which is main-thread occupancy, whoever
/// caused it. A run loop that stays busy for 80ms has dropped four frames at
/// 60Hz, and that is precisely what a janky scroll is.
final class StallMonitor {
    static let shared = StallMonitor()

    /// One frame at 60Hz. Anything longer than this dropped a frame on any
    /// display Apple currently ships.
    private let frameBudget: TimeInterval = 0.0167

    private var observer: CFRunLoopObserver?
    private var wokeAt: CFAbsoluteTime = 0
    private let lock = NSLock()
    private var busyIntervals: [TimeInterval] = []
    private var totalBusy: TimeInterval = 0

    var hasSamples: Bool {
        lock.lock(); defer { lock.unlock() }
        return !busyIntervals.isEmpty
    }

    func start() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        // `order` as late as possible on wake and as late as possible before
        // sleeping, so the window brackets the frame's work rather than
        // landing inside it.
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, .max) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            switch activity {
            case .afterWaiting:
                self.wokeAt = now
            case .beforeWaiting:
                guard self.wokeAt > 0 else { return }
                self.record(now - self.wokeAt)
                self.wokeAt = 0
            default:
                break
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func record(_ interval: TimeInterval) {
        lock.lock()
        busyIntervals.append(interval)
        totalBusy += interval
        lock.unlock()
    }

    func reset() {
        lock.lock()
        busyIntervals.removeAll()
        totalBusy = 0
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let sorted = busyIntervals.sorted()
        let busy = totalBusy
        lock.unlock()
        guard !sorted.isEmpty else { return "  main thread: not sampled" }
        func percentile(_ fraction: Double) -> TimeInterval {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.down))))
            return sorted[index]
        }
        let missed = sorted.filter { $0 > frameBudget }.count
        return String(
            format: "  main thread: %d run-loop passes, %.0fms busy, %d over %.1fms (%.1f%%), p50 %.2fms, p95 %.2fms, worst %.1fms",
            sorted.count, busy * 1000, missed, frameBudget * 1000,
            Double(missed) / Double(sorted.count) * 100,
            percentile(0.5) * 1000, percentile(0.95) * 1000, sorted[sorted.count - 1] * 1000
        )
    }
}
