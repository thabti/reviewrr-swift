import Foundation

/// How often Reviewrr checks watched projects, as the three answers worth
/// offering.
///
/// A model type rather than a nested one in the pane, for the reason the
/// project states in `AGENTS.md`: `ViewModels/` and `Models/` compile into
/// the test bundle and `Views/` does not, so logic a test should pin down
/// cannot live in a view.
///
/// ## What these replaced
///
/// A stepper for the interval in 30-second steps, a second stepper for the
/// backoff ceiling, and a jitter slider in percent. Jitter keeps twenty
/// watched projects from firing in the same second — a correctness detail of
/// the polling loop, not a preference — and nobody has a view on 20% versus
/// 30% of it.
/// The three rates worth offering, plus off.
///
/// Values chosen against the rate limit rather than for round numbers:
/// GitHub allows 5,000 requests an hour, one project costs a handful per
/// poll, and 2 minutes across a dozen projects is comfortably inside it.
enum PollRate: Int, CaseIterable, Identifiable {
    case relaxed = 900
    case normal = 300
    case fast = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    var summary: String {
        switch self {
        case .relaxed: return "Checks every 15 minutes. Kindest to a shared rate limit."
        case .normal: return "Checks every 5 minutes. The right answer for most teams."
        case .fast: return "Checks every 2 minutes. For a busy review day."
        }
    }

    var systemImage: String {
        switch self {
        case .relaxed: return "tortoise"
        case .normal: return "clock"
        case .fast: return "hare"
        }
    }

    var hint: String {
        switch self {
        case .relaxed: return "Every 15 min"
        case .normal: return "Every 5 min"
        case .fast: return "Every 2 min"
        }
    }
}
