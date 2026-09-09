import SwiftUI

/// The right-rail panel hosting the Conversation and Checks tabs.
/// `ConversationModel` is constructed and loaded once per PR by whoever
/// wires this into the workspace; this view owns no PR-loading state of
/// its own, only tab selection.
///
/// It shares its chrome — identity field, mark, rail switcher, status strip,
/// underlined tabs — with the AI panel, in the accent colour rather than AI
/// purple, so the two rails are told apart by identity rather than by
/// reading a segment label, and their tab bars and content start at exactly
/// the same height.
struct ConversationPanelView: View {
    @ObservedObject var model: ConversationModel
    @Binding var rail: AppModel.InspectorRail
    let onNavigate: (String, Int, DiffSide) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case checks = "Checks"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right"
            case .checks: return "checkmark.seal"
            }
        }

        var help: String {
            switch self {
            case .conversation: return "Review threads, comments, and reviews"
            case .checks: return "CI checks for the head commit"
            }
        }
    }

    @State private var tab: Tab = .conversation
    /// Resolution state is a pass over every thread. Cached and refreshed
    /// when the threads themselves change, so a reply landing or a filter
    /// toggling does not re-tally a 200-thread pull request.
    @State private var tally = ConversationModel.ResolutionTally()

    var body: some View {
        VStack(spacing: 0) {
            InspectorIdentityHeader(
                rail: .conversation,
                subtitle: { Text(subtitle) },
                // Empty: the rail switcher sits in the inspector's own
                // toolbar band, above this header, so it is not repeated
                // inside each panel.
                trailing: { EmptyView() },
                status: { statusStrip }
            )
            InspectorTabBar(tabs: tabs, selection: $tab, tint: AppModel.InspectorRail.conversation.tint)
                .motion(Motion.smooth, value: model.checkRollup.overallState)

            Group {
                switch tab {
                case .conversation:
                    ConversationTimelineView(model: model, onNavigate: onNavigate)
                case .checks:
                    ChecksListView(model: model)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .safeAreaPadding(.bottom, 24)
            .id(tab)
            // A cross-fade, not a slide. Switching tabs inside a panel is
            // not content arriving from off-screen, and the app no longer
            // slides anything sideways — the surface swap on opening a pull
            // request was the last one, and it reads as an overlay.
            .motionTransition(.opacity)
            .motion(Motion.smooth, value: tab)
        }
        .onAppear { tally = model.resolutionTally }
        .onChange(of: model.threads) { _, _ in tally = model.resolutionTally }
    }

    // MARK: - Status strip

    /// CI state and the one action this rail actually has. Reviewrr can
    /// re-fetch checks; it cannot re-fetch the discussion from here, so this
    /// strip does not offer to.
    private var statusStrip: some View {
        HStack(spacing: Theme.Space.s) {
            checksChip
            Spacer(minLength: Theme.Space.xs)
            Button {
                Task { await model.refreshChecks() }
            } label: {
                Label("Refresh checks", systemImage: "arrow.clockwise")
                    .font(.system(size: Theme.captionSize, weight: .medium))
            }
            .buttonStyle(.reviewrrSecondary)
            .controlSize(.small)
            .disabled(model.checksLoadPhase == .loading)
            .help("Fetch the check runs for the head commit again")
            .accessibilityLabel("Refresh checks for the head commit")
        }
        .motion(Motion.smooth, value: model.checkRollup)
    }

    /// GitHub's verdict on the head commit, stated as GitHub gives it.
    ///
    /// "No checks reported" is not the same claim as "we have not asked",
    /// and neither is a pass: a repository with no CI, a repository whose
    /// CI is green, and a fetch that has not happened are three different
    /// facts, and `CheckRollup.empty` looks identical to the first of them.
    /// So the load phase is consulted before the rollup is believed.
    @ViewBuilder
    private var checksChip: some View {
        switch model.checksLoadPhase {
        case .idle:
            StatusChip(text: "Checks not loaded", systemImage: "questionmark.circle", palette: .neutral)
                .help("Reviewrr has not fetched the check runs for this commit yet")
                .accessibilityLabel("Checks not loaded yet")
        case .failed:
            StatusChip(text: "Checks unavailable", systemImage: "exclamationmark.triangle.fill", palette: .orange)
                .help("The last attempt to fetch checks failed — open the Checks tab for GitHub's message")
                .accessibilityLabel("Checks could not be loaded")
        case .loading:
            PulsingStatusChip(text: "Loading checks…", palette: .blue)
                .help("Fetching the check runs for the head commit")
                .accessibilityLabel("Loading checks")
        case .loaded:
            rollupChip
        }
    }

    @ViewBuilder
    private var rollupChip: some View {
        let rollup = model.checkRollup
        switch rollup.overallState {
        case .noChecks:
            StatusChip(text: "No checks reported", systemImage: "minus.circle", palette: .neutral)
                .help("GitHub returned no check runs or commit statuses for the head commit")
                .accessibilityLabel("No checks reported for the head commit")
        case .failure:
            let failing = rollup.countsByConclusion.filter { $0.key.isFailing }.values.reduce(0, +)
            StatusChip(text: "\(failing) failing", systemImage: "xmark.octagon.fill", palette: .red)
                .help("\(failing) of \(rollup.totalCount) check\(rollup.totalCount == 1 ? "" : "s") failed on the head commit")
                .accessibilityLabel("\(failing) failing check\(failing == 1 ? "" : "s")")
        case .pending:
            // Checks still running is real in-flight work, so it is the one
            // rollup state that earns a pulse.
            PulsingStatusChip(text: "\(rollup.pendingCount) running", palette: .blue)
                .help("\(rollup.pendingCount) check\(rollup.pendingCount == 1 ? "" : "s") still running on the head commit")
                .accessibilityLabel("\(rollup.pendingCount) check\(rollup.pendingCount == 1 ? "" : "s") still running")
        case .success:
            StatusChip(text: "All checks passed", systemImage: "checkmark.seal.fill", palette: .green)
                .help("All \(rollup.totalCount) check\(rollup.totalCount == 1 ? "" : "s") passed on the head commit")
                .accessibilityLabel("All \(rollup.totalCount) checks passed")
        }
    }

    private var tabs: [InspectorTab<Tab>] {
        [
            InspectorTab(
                value: .conversation, title: Tab.conversation.rawValue, symbol: Tab.conversation.symbol,
                help: Tab.conversation.help, badge: unresolvedBadge,
                badgeDescription: { "\($0) unresolved" }
            ),
            InspectorTab(
                value: .checks, title: Tab.checks.rawValue, symbol: Tab.checks.symbol,
                help: Tab.checks.help, badge: actionableCheckCount,
                badgeDescription: { "\($0) failing or running" },
                alert: model.checkRollup.overallState == .failure
            ),
        ]
    }

    /// Resolution state comes from GraphQL, and a thread whose state never
    /// arrived is `.unknown` — not unresolved. Counting those as unresolved
    /// made the badge assert "12 unresolved" over twelve cards that each
    /// honestly read "Unknown". When any thread is unknown there is no
    /// number to show, so the badge is absent and `subtitle` says why.
    private var unresolvedBadge: Int? {
        guard !tally.isIncomplete else { return nil }
        return tally.unresolved
    }

    /// Only checks that ask something of the reviewer — failing or still
    /// running. The total was a neutral fact styled exactly like the
    /// actionable unresolved and finding badges next to it.
    private var actionableCheckCount: Int {
        let rollup = model.checkRollup
        let failing = rollup.countsByConclusion.filter { $0.key.isFailing }.values.reduce(0, +)
        return failing + rollup.pendingCount
    }

    /// Opens with where this rail's content comes from, for the same reason
    /// the AI rail opens with "Read-only": the two panels sit side by side
    /// and a reviewer must never have to work out which one is quoting
    /// GitHub.
    private var subtitle: String {
        if model.loadPhase == .loading { return "From GitHub · loading conversation…" }
        let threads = tally.total
        let threadPart = "From GitHub · \(threads) thread\(threads == 1 ? "" : "s")"
        if threads == 0 { return threadPart }
        if tally.isIncomplete { return "\(threadPart) · resolved state unavailable" }
        return tally.unresolved > 0 ? "\(threadPart) · \(tally.unresolved) unresolved" : threadPart
    }
}
