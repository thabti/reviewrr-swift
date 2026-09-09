import SwiftUI

/// The Checks tab: every CI result for the PR's current head commit, with
/// a manual refresh — checks are polled/refreshed only on explicit
/// request, never by a background timer — and a link out to each
/// provider's own detail page.
struct ChecksListView: View {
    @ObservedObject var model: ConversationModel

    /// No header band of its own. The rollup verdict and the Refresh
    /// action used to sit here, about forty points below the identical pair
    /// in the panel's own status strip; they now live only in the strip,
    /// where they stay visible from the Conversation tab too.
    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch model.checksLoadPhase {
        case .idle:
            EmptyStateView(
                systemImage: "checkmark.seal", title: "Checks not loaded yet",
                message: "Use Refresh checks above to fetch the check runs for the head commit."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.checks.isEmpty:
            PanelLoadingList(message: "Loading checks…")
        case .failed(let message):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load checks", message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.checks.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.seal",
                    title: "No checks reported",
                    message: "This commit has no CI checks or commit statuses."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    /// Failing checks first, then pending, then everything else — the
    /// reviewer's next action lives at the top of the list rather than
    /// buried among checks that already passed.
    private var orderedChecks: [CheckRun] {
        model.checks.sorted { lhs, rhs in
            Self.triageRank(lhs) < Self.triageRank(rhs)
        }
    }

    private static func triageRank(_ check: CheckRun) -> Int {
        guard check.status == .completed else { return 1 }
        return check.isFailing ? 0 : 2
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(orderedChecks) { check in
                    CheckRunRow(check: check)
                        .motionTransition(.reviewrrRow)
                }
            }
            .padding(12)
            .motion(Motion.smooth, value: model.checks)
        }
    }
}

private struct CheckRunRow: View {
    let check: CheckRun

    private var icon: String {
        guard check.status == .completed else { return "circle.dotted" }
        switch check.conclusion {
        case .success: return "checkmark.circle.fill"
        case .failure, .timedOut, .actionRequired: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .neutral, .skipped, .stale, .none: return "circle.fill"
        }
    }

    private var palette: StatusPalette {
        guard check.status == .completed else { return .neutral }
        switch check.conclusion {
        case .success: return .green
        case .failure, .timedOut, .actionRequired: return .red
        case .cancelled: return .orange
        case .neutral, .skipped, .stale, .none: return .neutral
        }
    }

    private var tint: Color { palette.label }

    /// Neutral, skipped, stale and "completed with no conclusion at all" all
    /// drew the same grey dot, so four different outcomes were one glyph and
    /// nothing on the row said which. Every state gets a word — the row's
    /// only channel that survives a colour-vision difference, a greyscale
    /// screenshot, or VoiceOver.
    private var stateWord: String {
        switch check.status {
        case .queued: return "Queued"
        case .inProgress: return "Running"
        case .completed:
            switch check.conclusion {
            case .success: return "Passed"
            case .failure: return "Failed"
            case .timedOut: return "Timed out"
            case .actionRequired: return "Action required"
            case .cancelled: return "Cancelled"
            case .neutral: return "Neutral"
            case .skipped: return "Skipped"
            case .stale: return "Stale"
            case .none: return "No result"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(check.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(check.name)
                Text(stateWord)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let duration = check.duration {
                    Text(Self.format(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if let url = check.detailsURL {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                        .foregroundStyle(.secondary)
                        .help("Open \(check.name) details")
                        .accessibilityLabel("Open \(check.name) details")
                }
            }
            if let appName = check.appName, appName.lowercased() != check.name.lowercased() {
                Text(appName).font(.caption2).foregroundStyle(.secondary)
            }
            if let title = check.outputTitle, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            if check.isFailing, let summary = check.outputSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .reviewrrCard()
        .motion(Motion.smooth, value: check)
        // `.combine` flattened the row and swallowed the details link with
        // it, so a VoiceOver user could hear a check had failed but never
        // reach the page explaining why.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(check.name), \(stateWord)")
    }

    private static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remain = seconds % 60
        return "\(minutes)m \(remain)s"
    }
}
