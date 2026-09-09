import AppKit
import SwiftUI

/// The sidebar's pull-request identity block: state, size, age, branches,
/// and the repository's own labels.
///
/// The PR *title* is deliberately absent. It is the window title and it is
/// in the toolbar chip; repeating it a third time here cost three lines of a
/// narrow column and told the reviewer nothing they weren't already looking
/// at. What the sidebar adds instead is the metadata that used to be buried
/// in a popover — labels most of all, since "breaking", "needs-qa" or
/// "do-not-merge" changes how the whole diff should be read.
///
/// The first row is exactly `Theme.panelHeaderHeight` tall and carries no
/// padding of its own beyond the shared `Space.m` inset, so the left
/// column's identity line, the diff toolbar and the right rail's header all
/// start on the same baseline across the window. Everything below it is
/// disclosure: the header stays put when the details fold away.
struct PRSummaryCard: View {
    let pr: PullRequest
    let reference: PRReference

    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityRow
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.panelHeaderHeight)

            if expanded {
                details
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.m)
                    .motionTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    /// State on the left edge, size on the right, disclosure at the end —
    /// the same left-anchor/right-anchor rhythm the file rows below use, so
    /// the column has one right margin rather than a ragged one.
    private var identityRow: some View {
        HStack(spacing: Theme.Space.s) {
            StatusPill(pr: pr)
                .help("This pull request is \(stateDescription)")
                .accessibilityLabel("State: \(stateDescription)")

            Spacer(minLength: Theme.Space.s)

            DiffStatCounts(additions: pr.additions, deletions: pr.deletions)
                .help("\(pr.additions) additions, \(pr.deletions) deletions")
                .accessibilityLabel("\(pr.additions) additions, \(pr.deletions) deletions")

            Button {
                withAnimation(reduceMotion ? nil : Motion.snappy) { expanded.toggle() }
            } label: {
                // The glyph alone was a ~10pt target with nothing to say
                // it was clickable: the frame is the hit area, the
                // highlight is the invitation to use it.
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Theme.iconMediumSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide pull request details" : "Show pull request details")
            .accessibilityLabel(expanded ? "Hide pull request details" : "Show pull request details")
        }
    }

    // MARK: - Rows

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(sizeLine)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(sizeAccessibilityLabel)

            authorRow
            branchRow
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "number")
                    .font(.system(size: Theme.iconSmallSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                CopyableText(
                    text: String(pr.headSha.prefix(7)), name: "head commit",
                    font: Theme.monoFontSmall, color: .secondary,
                    extraActions: [("Copy full SHA", pr.headSha)]
                )
                Spacer(minLength: 0)
            }
            GitHubLabelRow(labels: pr.labels)
            // The tracker keys, wherever they were written — the title, the
            // description, or only the branch name. Absent entirely when
            // there are none, so a pull request with no issue carries no
            // empty row.
            IssueKeyChips(title: pr.title, description: pr.body, branch: pr.head.ref)
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorRow: some View {
        HStack(spacing: Theme.Space.xs) {
            AvatarView(urlString: pr.user.avatarUrl, size: 16)

            Text(pr.user.login).font(Theme.captionEmphasis).lineLimit(1)
            Text("opened").font(Theme.caption).foregroundStyle(.secondary)
            Text(pr.createdAt, style: .relative).font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .help("Opened by \(pr.user.login)")
        .accessibilityElement(children: .combine)
    }

    private var branchRow: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: Theme.iconSmallSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Branch names are prose, not code. The proportional face fits
            // about a fifth more of a long `feature/...` name into the same
            // column before it truncates; monospace stays where character
            // alignment carries meaning, which is SHAs, not refs.
            CopyableText(
                text: pr.baseRef, name: "base branch", color: .secondary,
                extraActions: [("Copy git switch command", "git switch \(pr.baseRef)")]
            )
            Image(systemName: "arrow.left")
                .font(.system(size: Theme.iconSmallSize, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // The head ref takes the rest of the row: it is the name the
            // reviewer does not already know, and the one they are most
            // likely to want on the clipboard — it is what you check out to
            // reproduce the change locally.
            CopyableText(
                text: pr.headRef, name: "branch name",
                extraActions: [
                    ("Copy git switch command", "git switch \(pr.headRef)"),
                    ("Copy git fetch command", "git fetch origin \(pr.headRef)"),
                ]
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The row is no longer one element: each branch is its own control,
        // so VoiceOver reaches them separately rather than hearing a summary
        // it cannot act on.
        .accessibilityElement(children: .contain)
    }

    /// Both actions stretch to share the column. Two small buttons huddled
    /// at the left edge left two thirds of the row empty and read as an
    /// afterthought under a block that fills its width.
    private var actionRow: some View {
        HStack(spacing: Theme.Space.s) {
            if let url = URL(string: pr.htmlUrl) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("GitHub", systemImage: "arrow.up.forward.square")
                        .font(Theme.caption)
                }
                .buttonStyle(.reviewrr(.secondary, fullWidth: true))
                .controlSize(.small)
                .help("Open \(reference.key) on GitHub")
                .accessibilityLabel("Open this pull request on GitHub")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.htmlUrl, forType: .string)
            } label: {
                Label("Copy link", systemImage: "link")
                    .font(Theme.caption)
            }
            .buttonStyle(.reviewrr(.secondary, fullWidth: true))
            .controlSize(.small)
            .help("Copy the pull request URL")
            .accessibilityLabel("Copy the pull request URL")
        }
    }

    // MARK: - Derived text

    private var stateDescription: String {
        if pr.merged { return "merged" }
        if pr.state == .closed { return "closed" }
        if pr.draft { return "a draft" }
        return "open"
    }

    private var sizeLine: String {
        "\(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s") · \(pr.commits) commit\(pr.commits == 1 ? "" : "s")"
    }

    private var sizeAccessibilityLabel: String {
        "\(pr.changedFiles) changed files, \(pr.commits) commits"
    }
}
