import AppKit
import SwiftUI

/// One inbox row: state, title, repo/author/age, CI and review signals, diff
/// size when known, labels, and local status — everything a reviewer needs
/// to triage without opening the PR. Every status signal pairs a colour
/// with a shape, symbol, or text so the row reads correctly for colour-blind
/// reviewers and doesn't rely on hue alone.
/// The signal column moves below the title when the inbox becomes narrow.
struct InboxRowView: View {
    /// Jira, when the team runs one. Published by the root view; disabled by
    /// default, and a disabled tracker adds nothing to a row.
    @Environment(\.issueTracker) private var tracker
    @Environment(\.reviewrrTextScale) private var scale
    let pr: InboxPR
    let localStatus: LocalPRStatus
    let isSelected: Bool
    /// False when the rows sit under a project header that already names the
    /// repository — repeating `owner/repo` on every row of a single-repo
    /// group is the second-largest thing competing with the titles.
    var showsRepository: Bool = true

    private var isUnseen: Bool { localStatus.isUnseen(currentUpdatedAt: pr.updatedAt) }
    private var isStale: Bool {
        localStatus.isUpdatedSinceReview(currentUpdatedAt: pr.updatedAt, currentHeadSha: pr.headSha)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                leading
                center.frame(minWidth: 300 * scale)
                trailing.fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .top, spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 8) {
                    center
                    trailing
                }
            }
        }
        .padding(.vertical, 10)
        // The signal cluster used to sit flush against the window's right
        // edge — the comment count read as clipped. The row owns its own
        // horizontal inset rather than leaving it to the list, so the
        // separators (pinned to these same edges) stay aligned with it.
        .padding(.horizontal, Theme.Space.l)
        .motion(Motion.smooth, value: localStatus)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Leading: unseen dot + state

    /// The unseen dot, and a state pill only when the state is worth a word.
    ///
    /// Every row in an inbox of open pull requests said "Open", which is the
    /// definition of a badge that carries no information: eleven identical
    /// green pills down the left edge, 84pt of column, competing with the
    /// titles for attention. Draft, merged and closed are the states worth
    /// naming, and they are the rare ones — which is exactly why a badge
    /// suits them. GitHub does the same thing: one state glyph, no repeated
    /// "Open" text on every row of a list that is already filtered to open.
    private var leading: some View {
        HStack(spacing: 6) {
            // Reserves its width whether or not the dot is filled, so titles
            // start at the same x on every row.
            Circle()
                .fill(isUnseen ? Theme.accent : Color.clear)
                .frame(width: Theme.scaled(7, scale), height: Theme.scaled(7, scale))
        }
        .padding(.top, Theme.scaled(3, scale))
        // One width for every row, always. The state badge used to live
        // here, which made this column 84pt on a draft row and 13pt on an
        // open one — so titles started at two different x positions down a
        // mixed list, and the left edge read as broken. The badge moved next
        // to the title, where it belongs anyway: it qualifies the title, and
        // "Draft" beside "feat: integrate Aymakan carrier" is a sentence.
        .frame(width: Theme.scaled(13, scale), alignment: .leading)
        .motion(Motion.smooth, value: isUnseen)
    }

    // MARK: - Centre: title hero, identity line, labels

    private var center: some View {
        VStack(alignment: .leading, spacing: Theme.scaled(4, scale)) {
            // The title is the one thing that must dominate — a reviewer
            // scans this column, not the repo or author — so it gets the
            // largest, heaviest type in the row.
            HStack(alignment: .firstTextBaseline, spacing: Theme.scaled(6, scale)) {
                if pr.state != .open {
                    InboxStatePill(state: pr.state)
                }
                Text(pr.title)
                    .font(.reviewrr(15, scale: scale, weight: isUnseen ? .semibold : .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(pr.title)
            }

            HStack(spacing: Theme.scaled(6, scale)) {
                // `Text(verbatim:)`, not interpolation into a
                // `LocalizedStringKey`: that path formats an `Int` for the
                // locale and rendered merge request #8045 as "#8,045".
                // An identifier is never grouped.
                Text(verbatim: showsRepository ? "\(pr.repoNameWithOwner) #\(pr.number)" : "#\(pr.number)")
                    .font(.reviewrr(11, scale: scale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                PersonAvatar(login: pr.authorLogin, avatarURL: pr.authorAvatarURL.flatMap(URL.init(string:)))
                Text(pr.authorLogin)
                    .font(.reviewrr(12, scale: scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("·").font(.reviewrr(12, scale: scale)).foregroundStyle(.tertiary)

                Text(Self.relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: .now))
                    .font(.reviewrr(12, scale: scale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if localStatus.status != .none {
                    LocalStatusChip(status: localStatus.status)
                }

                // The issue this row belongs to, when the title or the branch
                // says so. One key here, not a row of them: the inbox is a
                // scanning surface, and the pull request's own header has the
                // full set.
                if let issue = primaryIssue {
                    IssueKeyChip(reference: issue, url: tracker.url(for: issue.key))
                }
            }

            if !pr.labels.isEmpty {
                LabelStrip(labels: pr.labels)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first issue key this row mentions, or nil.
    ///
    /// Title first, then the branch name: the title is the deliberate mention
    /// and the branch is the fallback for a pull request whose author only
    /// put the key there. The row has no description to scan.
    private var primaryIssue: IssueReference? {
        guard tracker.isUsable else { return nil }
        return IssueKeyDetector(settings: tracker)
            .keys(title: pr.title, branch: pr.headRef)
            .first
    }

    // MARK: - Trailing: the signal cluster reclaiming the empty half

    private var trailing: some View {
        // The signals are fixed-size facts; the title is the elastic one.
        // Without this the cluster was the side that gave way and its
        // numbers were the thing that broke.
        VStack(alignment: .trailing, spacing: Theme.scaled(6, scale)) {
            HStack(spacing: Theme.scaled(9, scale)) {
                if pr.ciState != .unknown || pr.host.isGitHub {
                    CIStatusIndicator(state: pr.ciState)
                        .frame(width: Theme.scaled(16, scale))
                }
                if pr.reviewDecision != .none || pr.host.isGitHub {
                    ReviewDecisionIndicator(decision: pr.reviewDecision)
                        .frame(width: Theme.scaled(16, scale))
                }
                IconCount(
                    systemImage: "bubble.left", count: pr.commentCount,
                    tooltip: "\(pr.commentCount) comment\(pr.commentCount == 1 ? "" : "s")", mutedAtZero: true
                )
                // `minWidth`, not `width`: the columns still line up down the
                // list for the common one- and two-digit case, and a row with
                // a bigger number takes the space it needs instead of
                // wrapping inside a column that cannot hold it.
                .frame(minWidth: Theme.scaled(32, scale), alignment: .trailing)

                // Reserved width, but only where the numbers can arrive.
                //
                // These columns are held open on GitHub so they do not jump
                // when the batched GraphQL enrichment lands. GitLab's merge
                // request list carries no diff stats at all — reserving for
                // them there held 112pt of every row open for numbers that
                // were never coming, which is the empty band down the middle
                // of a GitLab inbox.
                if pr.host.isGitHub || pr.additions != nil {
                    Group {
                        if let additions = pr.additions, let deletions = pr.deletions {
                            // Abbreviated, and on one line. A release
                            // branch's "+32,940 −9,658" did not fit the
                            // column and wrapped into two half-numbers
                            // stacked on top of each other — the exact
                            // opposite of a glanceable size.
                            InboxDiffSize(additions: additions, deletions: deletions)
                        }
                    }
                    .frame(minWidth: Theme.scaled(74, scale), alignment: .trailing)
                }

                if pr.host.isGitHub || pr.changedFiles != nil {
                    Group {
                        if let changedFiles = pr.changedFiles {
                            IconCount(
                                systemImage: "doc.on.doc", count: changedFiles,
                                tooltip: "\(changedFiles) file\(changedFiles == 1 ? "" : "s") changed"
                            )
                        }
                    }
                    .frame(minWidth: Theme.scaled(38, scale), alignment: .trailing)
                }

                if isStale {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.reviewrr(11, scale: scale, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Updated since you last reviewed it")
                        .accessibilityLabel("Updated since review")
                }

                ReviewerAvatarStack(host: pr.host, reviewers: pr.requestedReviewers)
            }

        }
    }

    private var accessibilitySummary: String {
        var parts = [
            "\(pr.state.label) \(pr.host.forge.changeNoun) #\(pr.number), \(pr.title), by \(pr.authorLogin), in \(pr.repoNameWithOwner)",
            "updated \(Self.relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: .now))",
        ]
        if isUnseen { parts.append("unseen") }
        switch pr.ciState {
        case .success: parts.append("checks passing")
        case .failure: parts.append("checks failing")
        case .pending: parts.append("checks running")
        case .unknown: break
        }
        switch pr.reviewDecision {
        case .approved: parts.append("approved")
        case .changesRequested: parts.append("changes requested")
        case .reviewRequired: parts.append("review required")
        case .none: break
        }
        if isStale { parts.append("updated since your review") }
        parts.append("status \(localStatus.status.label)")
        return parts.joined(separator: ", ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// A pull request's size, short enough to read at a glance.
///
/// Thousands become "3.6k": the exact line count of a release branch is not a
/// triage signal, its order of magnitude is, and the precise number is in the
/// tooltip for anyone who wants it.
private struct InboxDiffSize: View {
    @Environment(\.reviewrrTextScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: Theme.scaled(4, scale)) {
            Text("+" + InboxDiffSizeFormatting.abbreviate(additions))
                .foregroundStyle(DiffTextColor.added(colorScheme))
            Text("−" + InboxDiffSizeFormatting.abbreviate(deletions))
                .foregroundStyle(DiffTextColor.removed(colorScheme))
        }
        .font(.reviewrr(11, scale: scale, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .help("\(additions) additions, \(deletions) deletions")
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

// MARK: - Leading

private struct InboxStatePill: View {
    @Environment(\.reviewrrTextScale) private var scale
    let state: InboxPRState

    private var color: Color {
        switch state {
        case .open: return .green
        case .draft: return .secondary
        case .merged: return .purple
        case .closed: return .red
        }
    }

    /// A distinct glyph per state, deliberately different from the CI and
    /// review-decision glyphs even where the colour matches (e.g. merged's
    /// purple vs. approved's green) — colour alone never carries meaning.
    private var symbol: String {
        switch state {
        case .open: return "arrow.triangle.pull"
        case .draft: return "pencil.circle"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    var body: some View {
        Label(state.label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.reviewrr(10, scale: scale, weight: .semibold))
            .imageScale(.small)
            .padding(.horizontal, Theme.scaled(6, scale))
            .padding(.vertical, Theme.scaled(2, scale))
            // A fill *and* a border. At 0.16 alpha alone, draft's secondary
            // grey sat on a grey row as a smudge — legible as a shape but
            // not as a badge. The border gives it an edge at any row
            // background, and the caps make the word read at 10pt.
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(state == .draft ? Color.primary.opacity(0.75) : color)
            .textCase(.uppercase)
            .fixedSize()
            .accessibilityLabel(state.label)
    }
}

// MARK: - Centre

/// A circular avatar with a whole-point frame, a hairline border, and a
/// graceful placeholder — initials when the login parses, a person symbol
/// otherwise — so a slow or missing avatar never leaves a raw square or an
/// empty gap while loading.
///
/// Backed by `AvatarImageCache` rather than a bare `AsyncImage`: scrolling a
/// 150-row inbox repeatedly re-mounts the same handful of rows (and with
/// them, the same handful of author/reviewer avatar URLs), and `AsyncImage`
/// has no cache of its own — every re-mount re-fetches and re-decodes.
private struct PersonAvatar: View {
    @Environment(\.reviewrrTextScale) private var scale
    let login: String
    let avatarURL: URL?
    var diameter: CGFloat = 15

    @State private var loadedImage: NSImage?

    private var side: CGFloat { Theme.scaled(diameter, scale) }

    var body: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage).resizable().scaledToFill()
            } else if let avatarURL {
                placeholder
                    .task(id: avatarURL) {
                        loadedImage = await AvatarImageCache.shared.load(avatarURL)
                    }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private var placeholder: some View {
        Circle()
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                if let initial = login.first {
                    Text(String(initial).uppercased())
                        .font(.reviewrr(9, scale: scale, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "person.fill")
                        .font(.reviewrr(8, scale: scale))
                        .foregroundStyle(.secondary)
                }
            }
    }
}

/// Labels capped at a fixed count with a "+N" overflow, never wrapping —
/// a heavily-labelled PR must not push the row to three lines.
private struct LabelStrip: View {
    @Environment(\.reviewrrTextScale) private var scale
    let labels: [GitHubLabel]
    /// Two, not three. A row carrying four coloured pills reads as a label
    /// list with a title attached rather than a pull request with labels.
    private let cap = 2

    var body: some View {
        HStack(spacing: Theme.scaled(4, scale)) {
            ForEach(labels.prefix(cap)) { InboxLabelChip(label: $0) }
            if labels.count > cap {
                Text("+\(labels.count - cap)")
                    .font(.reviewrr(10, scale: scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.scaled(5, scale))
                    .padding(.vertical, Theme.scaled(1, scale))
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .accessibilityLabel("\(labels.count - cap) more labels")
            }
        }
    }
}

/// One GitHub label, tinted with its own colour rather than raw hex text.
private struct InboxLabelChip: View {
    @Environment(\.reviewrrTextScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    let label: GitHubLabel

    var body: some View {
        Text(label.name)
            .font(.reviewrr(10, scale: scale, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, Theme.scaled(6, scale))
            .padding(.vertical, Theme.scaled(1, scale))
            .background(rawColor.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(rawColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(legibleForeground)
            .help(label.name)
            .accessibilityLabel("Label: \(label.name)")
    }

    private var rgb: (r: Double, g: Double, b: Double)? {
        var hex = label.color
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private var rawColor: Color {
        guard let rgb else { return .secondary }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// GitHub label colors are arbitrary — a pale one like `#fef2c0` reads
    /// as text only on a light background, and a near-black one only on a
    /// dark one. Darkening/lightening toward each appearance's ink keeps
    /// every label legible while it still reads as "that label's colour,"
    /// rather than printing the raw hex value's brightness verbatim.
    private var legibleForeground: Color {
        guard let rgb else { return .secondary }
        let luminance = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        if colorScheme == .light, luminance > 0.6 {
            return Color(red: rgb.r * 0.55, green: rgb.g * 0.55, blue: rgb.b * 0.55)
        }
        if colorScheme == .dark, luminance < 0.35 {
            return Color(
                red: rgb.r + (1 - rgb.r) * 0.55,
                green: rgb.g + (1 - rgb.g) * 0.55,
                blue: rgb.b + (1 - rgb.b) * 0.55
            )
        }
        return rawColor
    }
}

// MARK: - Trailing

/// CI state, distinguished by symbol as well as colour: a pass/fail glyph
/// reads correctly without colour, and pending is the row's one legitimate
/// looping indicator — checks really are still running. Unknown renders
/// nothing, but the fixed-width slot around this view still holds its
/// place so neighbouring signals never shift.
private struct CIStatusIndicator: View {
    @Environment(\.reviewrrTextScale) private var scale
    let state: InboxCIState

    var body: some View {
        switch state {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.reviewrr(13, scale: scale, weight: .semibold))
                .foregroundStyle(.green)
                .help("Checks passing")
                .accessibilityLabel("Checks passing")
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.reviewrr(13, scale: scale, weight: .semibold))
                .foregroundStyle(.red)
                .help("Checks failing")
                .accessibilityLabel("Checks failing")
        case .pending:
            ActivityDot(color: .yellow, size: Theme.scaled(8, scale))
                .help("Checks running")
                .accessibilityLabel("Checks running")
        case .unknown:
            EmptyView()
        }
    }
}

/// The reviewer's decision on this PR, icon-only here (the trailing column
/// is a scan column, not a reading column) with the full word in the
/// tooltip and accessibility label. Distinct glyphs from `CIStatusIndicator`
/// even where the colour matches, so approval and green CI never look like
/// the same signal at a glance.
private struct ReviewDecisionIndicator: View {
    @Environment(\.reviewrrTextScale) private var scale
    let decision: InboxReviewDecision

    var body: some View {
        switch decision {
        case .approved:
            Image(systemName: "checkmark.seal.fill")
                .font(.reviewrr(13, scale: scale, weight: .semibold))
                .foregroundStyle(.green)
                .help("Approved")
                .accessibilityLabel("Approved")
        case .changesRequested:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.reviewrr(13, scale: scale, weight: .semibold))
                .foregroundStyle(.red)
                .help("Changes requested")
                .accessibilityLabel("Changes requested")
        case .reviewRequired:
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.reviewrr(13, scale: scale, weight: .semibold))
                .foregroundStyle(.blue)
                .help("Review required")
                .accessibilityLabel("Review required")
        case .none:
            EmptyView()
        }
    }
}

/// A muted-at-zero icon + count, shared shape for comments and changed
/// files so the two slots read as the same kind of signal.
private struct IconCount: View {
    @Environment(\.reviewrrTextScale) private var scale
    let systemImage: String
    let count: Int
    let tooltip: String
    var mutedAtZero: Bool = false

    var body: some View {
        Label {
            Text(InboxDiffSizeFormatting.abbreviate(count))
                .monospacedDigit()
                // A count is one token. Left to wrap inside a fixed column,
                // "31" became "3" over "1" and "702" became "70" over "2" —
                // digits stacked into a different number entirely.
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.reviewrr(11, scale: scale, weight: .medium))
        .foregroundStyle(mutedAtZero && count == 0 ? Color.secondary.opacity(0.45) : Color.secondary)
        .fixedSize()
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

/// Requested-reviewer avatars, overlapping slightly the way Mail and GitHub
/// stack them. `InboxPR` only carries reviewer logins, not their avatar
/// URLs, so each avatar is fetched from GitHub's own `/<login>.png` route —
/// the same host-relative pattern the rest of the app already uses to build
/// web links (`webBaseURL`), so it resolves correctly on Enterprise too.
private struct ReviewerAvatarStack: View {
    @Environment(\.reviewrrTextScale) private var scale
    let host: ForgeHost
    let reviewers: [String]
    private let maxShown = 3

    private var side: CGFloat { Theme.scaled(14, scale) }

    var body: some View {
        if !reviewers.isEmpty {
            HStack(spacing: -Theme.scaled(5, scale)) {
                ForEach(Array(reviewers.prefix(maxShown).enumerated()), id: \.offset) { _, login in
                    PersonAvatar(login: login, avatarURL: avatarURL(for: login), diameter: 14)
                }
                if reviewers.count > maxShown {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.25))
                        Text("+\(reviewers.count - maxShown)")
                            .font(.reviewrr(9, scale: scale, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: side, height: side)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
            }
            .help("Requested reviewers: \(reviewers.joined(separator: ", "))")
            .accessibilityLabel("Requested reviewers: \(reviewers.joined(separator: ", "))")
        }
    }

    private func avatarURL(for login: String) -> URL? {
        host.webBaseURL.appendingPathComponent("\(login).png")
    }
}

private struct LocalStatusChip: View {
    @Environment(\.reviewrrTextScale) private var scale
    let status: LocalReviewStatus

    private var color: Color {
        switch status {
        case .none: return .secondary
        case .inReview: return .blue
        case .reviewed: return .green
        case .ignored: return .secondary
        }
    }

    var body: some View {
        if status != .none {
            Text(status.label)
                .font(.reviewrr(11, scale: scale, weight: .semibold))
                .padding(.horizontal, Theme.scaled(6, scale))
                .padding(.vertical, Theme.scaled(3, scale))
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
                .fixedSize()
                .motionTransition(.reviewrrRow)
        }
    }
}

// MARK: - Avatar cache

/// A small, bounded, de-duplicating in-memory cache for the avatars
/// `PersonAvatar` shows. Two problems `AsyncImage` alone doesn't solve:
///
/// - No cache: a row scrolled off-screen and back re-fetches and re-decodes
///   an avatar it already had.
/// - No de-duplication: several rows can share one reviewer's avatar URL
///   (`ReviewerAvatarStack`), and if they all scroll into view together each
///   would start its own redundant network request for the same bytes.
///
/// An actor serializes both concerns without any locking of our own; the
/// backing `NSCache` bounds memory and evicts under pressure on its own, so
/// there is no cleanup logic to get wrong.
actor AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {}

    func load(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
