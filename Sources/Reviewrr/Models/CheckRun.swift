import Foundation

/// GitHub reports CI progress through two separate surfaces: the modern
/// Checks API (`status`) and the legacy commit-status API (plain
/// pending/success/failure, no lifecycle). Both normalize onto this one
/// three-state lifecycle so the UI never has to branch on which surface a
/// given run came from.
enum CheckStatus: String, Equatable {
    case queued
    case inProgress = "in_progress"
    case completed
}

/// Only meaningful once `status == .completed`. Every case GitHub's Checks
/// API can report; the legacy status API only ever maps into `.success` or
/// `.failure`.
enum CheckConclusion: String, Equatable, CaseIterable {
    case success
    case failure
    case neutral
    case cancelled
    case skipped
    case timedOut = "timed_out"
    case actionRequired = "action_required"
    case stale

    /// Conclusions that should read as "this is broken" in a rollup —
    /// distinct from `.neutral`/`.skipped`/`.stale`, which did not run to a
    /// verdict but also did not fail one.
    var isFailing: Bool {
        switch self {
        case .failure, .timedOut, .actionRequired, .cancelled: return true
        case .success, .neutral, .skipped, .stale: return false
        }
    }
}

/// One normalized CI result, merged from either a GitHub Actions/App check
/// run or a legacy commit status. `id` is namespaced by source so the two
/// surfaces can never collide even if GitHub ever reused numeric ids across
/// them.
struct CheckRun: Identifiable, Equatable {
    enum Source: Equatable {
        case checkRun
        case legacyStatus
    }

    let id: String
    let name: String
    /// The reporting GitHub App's name for a check run, or the raw
    /// `context` string for a legacy status — whichever identifies *who*
    /// reported this, as distinct from `name`'s *what*.
    let appName: String?
    let status: CheckStatus
    let conclusion: CheckConclusion?
    let startedAt: Date?
    let completedAt: Date?
    let detailsURL: URL?
    let outputTitle: String?
    let outputSummary: String?
    let source: Source

    var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    var isFailing: Bool { conclusion?.isFailing ?? false }
}

/// The PR-header-level summary of every check: one overall state, counts
/// per conclusion (so a badge can read "3 passing, 1 failing" without the
/// caller re-deriving it), and the first failure to link to directly.
struct CheckRollup: Equatable {
    enum OverallState: Equatable {
        /// No checks reported at all — distinct from every check having
        /// passed, so the UI can say "no CI configured" rather than a
        /// misleading green dot.
        case noChecks
        case pending
        case failure
        case success
    }

    var overallState: OverallState
    var totalCount: Int
    var pendingCount: Int
    var countsByConclusion: [CheckConclusion: Int]
    var firstFailing: CheckRun?

    static let empty = CheckRollup(overallState: .noChecks, totalCount: 0, pendingCount: 0, countsByConclusion: [:], firstFailing: nil)

    static func compute(from runs: [CheckRun]) -> CheckRollup {
        guard !runs.isEmpty else { return .empty }

        var counts: [CheckConclusion: Int] = [:]
        var pending = 0
        var firstFailing: CheckRun?
        for run in runs {
            if run.status != .completed {
                pending += 1
                continue
            }
            if let conclusion = run.conclusion {
                counts[conclusion, default: 0] += 1
                if conclusion.isFailing && firstFailing == nil {
                    firstFailing = run
                }
            }
        }

        // A failure anywhere outranks "still running" — GitHub surfaces a
        // broken build immediately rather than waiting for every check to
        // finish, so a reviewer isn't left staring at a stale green dot.
        let overallState: OverallState
        if firstFailing != nil {
            overallState = .failure
        } else if pending > 0 {
            overallState = .pending
        } else {
            overallState = .success
        }

        return CheckRollup(
            overallState: overallState,
            totalCount: runs.count,
            pendingCount: pending,
            countsByConclusion: counts,
            firstFailing: firstFailing
        )
    }
}
