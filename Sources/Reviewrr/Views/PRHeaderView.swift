import AppKit
import SwiftUI

/// The toolbar's pull-request chip: which repository and number is open,
/// its state, and CI at a glance — with author, branches, age, review
/// decision, reviewer avatars and mergeability behind a click.
///
/// It deliberately does *not* repeat the title. The window title already
/// carries it and the sidebar carries the PR's labels and size, so a third
/// copy in the toolbar only cost horizontal room that the repository and
/// number — the thing a reviewer with several PRs open actually needs to
/// tell windows apart — now uses instead.
///
/// `reviews` come from `AppModel` via environment (already in the
/// integration contract's allowed read-only list) so the existing
/// `PRHeaderView(pr:reference:)` call site in `RootView` gets the richer
/// popover for free. `checkRollup` has no such shared source — it lives on
/// this track's own `ConversationModel` — so it stays an optional
/// parameter the integrator can wire in once a `ConversationModel` exists
/// alongside this view; until then the header simply omits the CI dot.
struct PRHeaderView: View {
    let pr: PullRequest
    let reference: PRReference
    var checkRollup: CheckRollup? = nil

    @EnvironmentObject private var appModel: AppModel
    @State private var showDetail = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            chip
        }
        // A `Menu`, not a `Button` with a popover. A chevron that opens
        // nothing was the symptom: `.popover(isPresented:)` anchored to a
        // view inside a `ToolbarItemGroup` presents unreliably, and a chip
        // wearing a disclosure chevron is promising a menu anyway. It now
        // holds one, and the popover it used to open is a first item.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 340, alignment: .leading)
        .help("\(pr.title)\n\(reference.key) — details, and switch pull request")
        .accessibilityLabel("Pull request \(reference.key)")
        .accessibilityHint("Shows details and other pull requests you can open")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            detail
                .padding(16)
                .frame(width: 340)
        }
    }

    /// The chip itself. Styled as a control at rest rather than only on
    /// hover: it is a popup button, and a macOS popup button does not wait to
    /// be hovered before admitting that it is one.
    private var chip: some View {
        HStack(spacing: 7) {
            StatusPill(pr: pr)
            Text("\(reference.owner)/\(reference.repo)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // Verbatim: an interpolated `Int` in a `LocalizedStringKey`
            // gets a grouping separator, turning #8045 into "#8,045".
            Text(verbatim: "#\(reference.number)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            if let checkRollup, checkRollup.overallState != .noChecks {
                CIRollupDot(state: checkRollup.overallState)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.controlFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }

    /// Details for the open pull request, then somewhere else to go.
    ///
    /// The chip is the one piece of chrome that always names where the
    /// reviewer is, which makes it the natural place to ask "and where else
    /// could I be" — the same role a document or branch popup plays in a
    /// native app.
    @ViewBuilder
    private var menuContent: some View {
        Button("Show Details…") { showDetail = true }
        if let url = URL(string: pr.htmlUrl) {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
        }
        Button("Copy Reference") { copy(reference.key) }
        Button("Copy Link") { copy(pr.htmlUrl) }

        let others = switchTargets
        if !others.isEmpty {
            Divider()
            Section("Switch to") {
                ForEach(others, id: \.reference.key) { target in
                    Button(target.label) {
                        Task { await appModel.open(target.reference) }
                    }
                }
            }
        }

        Divider()
        Button("Open Pull Request by URL…") { appModel.isOpenPRSheetPresented = true }
            .keyboardShortcut("o", modifiers: .command)
        Button("Back to Dashboard") { appModel.closePR() }
    }

    /// Where else the reviewer might want to be: what is in their inbox
    /// right now, then what they had open recently. Titles come from the
    /// inbox because a bare `owner/repo#12` is not a thing anyone recognises.
    private var switchTargets: [(reference: PRReference, label: String)] {
        var seen: Set<String> = [reference.key]
        var targets: [(reference: PRReference, label: String)] = []

        for row in appModel.dashboard.filteredRows where seen.insert(row.reference.key).inserted {
            targets.append((row.reference, "#\(row.number)  \(row.title)"))
            if targets.count >= 8 { break }
        }
        for key in appModel.settings.recentPRs {
            guard targets.count < 12, let parsed = PRReference.parse(key), seen.insert(key).inserted else { continue }
            targets.append((parsed, key))
        }
        return targets
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Detail popover

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPill(pr: pr)
                // The same copy vocabulary as the branch names: click,
                // right-click, select, or drag. A reference is the thing most
                // often pasted into a chat message about the review.
                CopyableText(
                    text: reference.key, name: "pull request reference", font: .headline,
                    extraActions: [("Copy pull request URL", pr.htmlUrl)]
                )
            }
            // The popover is where the full title lives now: asked for,
            // selectable, and free to wrap onto a second line.
            Text(pr.title)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 6) {
                AvatarView(urlString: pr.user.avatarUrl, size: 20)
                Text(pr.user.login).font(.caption.weight(.medium))
                Text("opened").font(.caption).foregroundStyle(.secondary)
                Text(pr.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Label("\(pr.baseRef) ← \(pr.headRef)", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Merging \(pr.headRef) into \(pr.baseRef)")

            HStack(spacing: 10) {
                DiffStatCounts(additions: pr.additions, deletions: pr.deletions)
                Text("\(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let checkRollup, checkRollup.overallState != .noChecks {
                HStack(spacing: 6) {
                    CIRollupDot(state: checkRollup.overallState)
                    Text(ciSummary(checkRollup)).font(.caption).contentTransition(.numericText())
                }
                .motion(Motion.smooth, value: checkRollup)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 6) {
                Circle().fill(mergeabilityColor).frame(width: 8, height: 8)
                Text(mergeabilityLabel).font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mergeability: \(mergeabilityLabel)")

            if !reviewerStates.isEmpty {
                HStack(spacing: 6) {
                    Text("Reviewers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(reviewerStates, id: \.user.login) { entry in
                        reviewerAvatar(entry)
                    }
                    Spacer(minLength: 0)
                    if let decision = reviewDecision {
                        ConversationReviewStateBadge(state: decision)
                    }
                }
            }
        }
    }

    /// A reviewer's decision was a coloured ring and nothing else, so
    /// "approved" and "blocked" — the two states that matter most on this
    /// row — were one shape in two hues. The badge carries the meaning; the
    /// ring keeps reinforcing it.
    private func reviewerAvatar(_ entry: (user: GitHubUser, state: ReviewState)) -> some View {
        AvatarView(urlString: entry.user.avatarUrl, size: 20)
            .overlay(Circle().strokeBorder(ringColor(for: entry.state), lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
                if let badge = ringBadge(for: entry.state) {
                    Image(systemName: badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ringColor(for: entry.state))
                        // Punched out of the avatar so the glyph reads at
                        // 8pt against whatever the photo happens to be.
                        .background(Circle().fill(Theme.cardBackground).frame(width: 11, height: 11))
                        .offset(x: 2, y: 2)
                }
            }
            .help("\(entry.user.login) — \(reviewStateLabel(entry.state))")
            .accessibilityHidden(false)
            .accessibilityLabel("\(entry.user.login), \(reviewStateLabel(entry.state))")
    }

    /// Only the two decisions get a badge. "Commented" and "pending" are not
    /// verdicts, and badging them would bury the two that are.
    private func ringBadge(for state: ReviewState) -> String? {
        switch state {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "xmark.circle.fill"
        case .commented, .pending, .dismissed: return nil
        }
    }

    // MARK: - Derived state

    /// The latest review state per reviewer — a local approximation of
    /// GitHub's own `reviewDecision`, which requires a separate GraphQL
    /// call this view has no reason to make on its own.
    private var reviewerStates: [(user: GitHubUser, state: ReviewState)] {
        var latest: [String: (user: GitHubUser, state: ReviewState, date: Date)] = [:]
        for review in appModel.reviews where review.state != .pending {
            let date = review.submittedAt ?? .distantPast
            if let existing = latest[review.user.login], existing.date > date { continue }
            latest[review.user.login] = (review.user, review.state, date)
        }
        return latest.values.sorted { $0.user.login < $1.user.login }.map { ($0.user, $0.state) }
    }

    private var reviewDecision: ReviewState? {
        let states = Set(reviewerStates.map(\.state))
        if states.contains(.changesRequested) { return .changesRequested }
        if states.contains(.approved) { return .approved }
        if states.contains(.commented) { return .commented }
        return nil
    }

    private func ringColor(for state: ReviewState) -> Color {
        switch state {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented, .pending: return .secondary
        case .dismissed: return .gray
        }
    }

    private func reviewStateLabel(_ state: ReviewState) -> String {
        switch state {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .commented: return "Commented"
        case .pending: return "Pending"
        case .dismissed: return "Dismissed"
        }
    }

    private func ciSummary(_ rollup: CheckRollup) -> String {
        switch rollup.overallState {
        case .success: return "All checks passed"
        case .failure:
            let failing = rollup.countsByConclusion.filter { $0.key.isFailing }.values.reduce(0, +)
            return "\(failing) check\(failing == 1 ? "" : "s") failing"
        case .pending: return "\(rollup.pendingCount) check\(rollup.pendingCount == 1 ? "" : "s") running"
        case .noChecks: return "No checks"
        }
    }

    /// GitHub's `mergeable_state` values, mapped to a plain-language label.
    /// `nil`/`"unknown"` means GitHub hasn't finished computing it yet —
    /// distinct from a real conflict, so it reads as "calculating" rather
    /// than a false "conflicts".
    private var mergeabilityLabel: String {
        if pr.merged { return "Merged" }
        if pr.state == .closed { return "Closed" }
        switch pr.mergeableState {
        case "clean": return "Ready to merge"
        case "unstable": return "Checks failing"
        case "dirty": return "Conflicts"
        case "blocked": return "Review required"
        case "behind": return "Behind base branch"
        case "draft": return "Draft"
        case "unknown", nil: return "Calculating…"
        case .some(let other): return other.capitalized
        }
    }

    private var mergeabilityColor: Color {
        switch pr.mergeableState {
        case "clean": return .green
        case "dirty", "blocked": return .red
        case "unstable": return .orange
        default: return .secondary
        }
    }
}

/// The CI rollup, in the toolbar chip and the detail popover.
///
/// It was a 6pt circle whose only channel was hue — red and green at that
/// size, in the same shape, is the textbook protanopia/deuteranopia failure,
/// and in the chip it is the *only* signal. `.help` revealed it on hover, and
/// a per-glance hover is not an at-a-glance indicator.
///
/// The glyphs are deliberately the same ones the per-check rows already use
/// (`ChecksListView.CheckRow.icon`), so the chip and the list it summarises
/// cannot disagree about what a state looks like. Colour now reinforces the
/// shape rather than carrying the meaning alone.
private struct CIRollupDot: View {
    let state: CheckRollup.OverallState

    private var color: Color {
        switch state {
        case .success: return .green
        case .failure: return .red
        case .pending: return .yellow
        case .noChecks: return .secondary
        }
    }

    private var symbol: String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        // A dotted ring rather than a filled one: pending has to be
        // distinguishable from passing in a screenshot, where the pulse
        // below is not.
        case .pending: return "circle.dotted"
        case .noChecks: return "circle"
        }
    }

    private var label: String {
        switch state {
        case .success: return "All checks passed"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .noChecks: return "No checks"
        }
    }

    var body: some View {
        // Pending checks are the one state that's genuine in-flight work, so
        // it stays the only one that moves — the "nothing loops without a
        // reason" rule. It is now the glyph that pulses rather than a bare
        // dot, so the shape still says "pending" when the motion is gone,
        // whether that is a screenshot or Reduce Motion.
        Image(systemName: symbol)
            .font(.system(size: Theme.iconSmallSize, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: state == .pending)
            .help(label)
            .accessibilityLabel(label)
    }
}
