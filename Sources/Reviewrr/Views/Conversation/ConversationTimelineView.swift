import SwiftUI

/// The Conversation tab: a filterable, chronological merge of general
/// (issue-level) comments, formal reviews, and inline review threads.
/// Outdated or unanchored threads render in their own labelled section
/// rather than being hidden or pinned to a diff line that no longer exists.
struct ConversationTimelineView: View {
    @ObservedObject var model: ConversationModel
    let onNavigate: (String, Int, DiffSide) -> Void

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
                .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private var filterBar: some View {
        Picker("Filter", selection: $model.filter) {
            ForEach(ConversationModel.Filter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // The same `Space.m` gutter the panel header and the timeline below
        // use, so the three blocks share one edge down the column.
        .padding(Theme.Space.m)
        .accessibilityLabel("Conversation filter")
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadPhase {
        case .idle:
            EmptyStateView(systemImage: "bubble.left.and.bubble.right", title: "No pull request loaded")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            PanelLoadingList(message: "Loading conversation…")
        case .failed(let message):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load discussion", message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            timeline
        }
    }

    private var timeline: some View {
        let (anchored, unanchored) = partition(model.filteredItems)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = model.lastError {
                    errorBanner(error)
                }
                if anchored.isEmpty && unanchored.isEmpty {
                    EmptyStateView(systemImage: "checkmark.bubble", title: emptyTitle, message: emptyMessage)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                ForEach(anchored) { item in row(for: item) }

                if !unanchored.isEmpty {
                    // "Unanchored" is the data model's word for three
                    // different situations and explains none of them. What
                    // the reviewer needs to know is that these threads have
                    // no line in the current diff to jump to.
                    sectionHeader("Not in the current diff", count: unanchored.count)
                    ForEach(unanchored) { item in row(for: item) }
                }
            }
            .padding(Theme.Space.m)
            // A thread resolving, a filter narrowing the list, or a reply
            // landing all reorder or remove rows — animated so the queue
            // visibly shrinks instead of jump-cutting to its new shape.
            .motion(Motion.smooth, value: model.filteredItems)
            .motion(Motion.smooth, value: model.lastError)
        }
    }

    @ViewBuilder
    private func row(for item: ConversationItem) -> some View {
        switch item {
        case .general(let comment):
            GeneralCommentCard(comment: comment)
                .motionTransition(.reviewrrRow)
        case .review(let review):
            ReviewSummaryCard(review: review)
                .motionTransition(.reviewrrRow)
        case .thread(let thread):
            ConversationThreadCard(model: model, thread: thread, onNavigate: onNavigate)
                .motionTransition(.reviewrrRow)
        }
    }

    private func partition(_ items: [ConversationItem]) -> (anchored: [ConversationItem], unanchored: [ConversationItem]) {
        var anchored: [ConversationItem] = []
        var unanchored: [ConversationItem] = []
        for item in items {
            if case .thread(let thread) = item, thread.isUnanchored {
                unanchored.append(item)
            } else {
                anchored.append(item)
            }
        }
        return (anchored, unanchored)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .help(title == "Not in the current diff"
              ? "These threads refer to lines that have changed since, or that GitHub no longer reports a position for — there is nowhere in the diff to jump to."
              : title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(.isHeader)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer()
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.reviewrrGhost)
            .controlSize(.small)
            .help("Dismiss error")
            .accessibilityLabel("Dismiss error")
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .motionTransition(.reviewrrRow)
        // `.combine` here flattened the banner into one static string and
        // took the dismiss button with it, leaving VoiceOver no way to clear
        // the error. Containers that hold controls get `.contain`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }

    private var emptyTitle: String {
        switch model.filter {
        case .all: return "No discussion yet"
        case .unresolved: return "Nothing unresolved"
        case .mine: return "No comments from you"
        case .sinceLastReview: return "Nothing new since your last review"
        }
    }

    private var emptyMessage: String? {
        switch model.filter {
        case .all: return "Comments, reviews, and inline threads will show up here."
        case .unresolved: return "Every thread on this PR is resolved."
        case .mine: return "You haven't commented or reviewed this PR yet."
        case .sinceLastReview: return "No new activity since you last submitted a review."
        }
    }
}

/// A general, issue-level comment — kept visually distinct from a formal
/// review or an inline thread comment, per the MVP plan's separation.
private struct GeneralCommentCard: View {
    let comment: IssueComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AvatarView(urlString: comment.user.avatarUrl, size: 18)

                Text(comment.user.login).font(.caption.weight(.semibold))
                Text(comment.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label("Comment", systemImage: "text.bubble")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if let url = URL(string: comment.htmlUrl) {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square").font(.caption2) }
                        .foregroundStyle(.secondary)
                        .help("Open this comment on GitHub")
                        .accessibilityLabel("Open comment on GitHub")
                }
            }
            MarkdownText(text: comment.body).font(.callout)
        }
        .padding(10)
        .reviewrrCard()
        .accessibilityElement(children: .contain)
    }
}

/// A submitted review's summary — its own state (approved/changes
/// requested/commented) and overall body, distinct from the inline
/// comments it may have attached.
private struct ReviewSummaryCard: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AvatarView(urlString: review.user.avatarUrl, size: 18)

                Text(review.user.login).font(.caption.weight(.semibold))
                if let submittedAt = review.submittedAt {
                    Text(submittedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                ConversationReviewStateBadge(state: review.state)
                if let url = review.htmlUrl.flatMap(URL.init(string:)) {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square").font(.caption2) }
                        .foregroundStyle(.secondary)
                        .help("Open this review on GitHub")
                        .accessibilityLabel("Open review on GitHub")
                }
            }
            if let body = review.body, !body.isEmpty {
                MarkdownText(text: body).font(.callout)
            }
        }
        .padding(10)
        // A neutral card, like every other GitHub-authored item here. It used
        // to be tinted with `Theme.accent`, which follows the macOS accent —
        // set to Purple that put a review summary in the same hue, built the
        // same way, as the AI card two tabs away. The state badge carries the
        // meaning; the container doesn't need to compete for it.
        .reviewrrCard()
        .accessibilityElement(children: .contain)
    }
}

/// Shared with `PRHeaderView`'s review-decision summary so the same badge
/// vocabulary (color, label) is used everywhere a review state appears.
struct ConversationReviewStateBadge: View {
    let state: ReviewState

    /// Same construction problem the AI severity badges had: `.green` over
    /// `.green.opacity(0.18)` is roughly 2:1 in light mode, so "Approved"
    /// was the least legible word on the card. `StatusPalette` picks a
    /// darkened label per appearance instead.
    private var palette: StatusPalette {
        switch state {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented, .pending, .dismissed: return .neutral
        }
    }

    private var symbol: String {
        switch state {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "exclamationmark.circle.fill"
        case .commented: return "text.bubble.fill"
        case .pending: return "clock.fill"
        case .dismissed: return "xmark.circle.fill"
        }
    }

    private var label: String {
        switch state {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .commented: return "Commented"
        case .pending: return "Pending"
        case .dismissed: return "Dismissed"
        }
    }

    var body: some View {
        StatusChip(text: label, systemImage: symbol, palette: palette)
            .accessibilityLabel(label)
    }
}
