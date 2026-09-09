import Foundation

/// Configuration for the automated scroll pass the review workspace runs
/// when it is being benchmarked.
///
/// A benchmark that needs a person to drag a trackpad is a benchmark nobody
/// re-runs, and one that needs synthetic input events needs Accessibility
/// permission that a build under `build/` will not have. So the pane scrolls
/// itself: same `LazyVStack`, same row materialization, same `body`
/// evaluations, driven from inside the process.
enum PerfScroll {
    /// `REVIEWRR_PERF_SCROLL=<seconds>` — how long each phase runs.
    /// Requires `REVIEWRR_PERF=1`; on its own it does nothing, because the
    /// numbers it exists to produce come from `PerfProbe`.
    static let seconds: Double? = {
        guard PerfProbe.isEnabled,
              let raw = ProcessInfo.processInfo.environment["REVIEWRR_PERF_SCROLL"],
              let value = Double(raw), value > 0
        else { return nil }
        return value
    }()

    static var isEnabled: Bool { seconds != nil }

    /// One step per frame at 60Hz. Faster than a person scrolls, on purpose:
    /// the question is whether the main thread can keep up with the display,
    /// not with a hand.
    static let stepNanoseconds: UInt64 = 16_666_666
}
