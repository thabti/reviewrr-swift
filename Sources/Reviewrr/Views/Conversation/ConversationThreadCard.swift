import SwiftUI

/// A rich, interactive card for one inline review thread in the
/// Conversation tab: every comment in the thread, a resolve/unresolve
/// action, and a reply composer. Distinct from `ThreadView`
/// (`CommentViews.swift`), which stays a lightweight read-only render for
/// Track C's inline diff — this one owns the human actions (reply,
/// resolve) that only make sense in the dedicated discussion panel.
struct ConversationThreadCard: View {
    @ObservedObject var model: ConversationModel
    let thread: ConversationThread
    let onNavigate: (String, Int, DiffSide) -> Void

    @State private var replyText = ""
    @State private var composerExpanded = false
    @State private var isExpanded: Bool?
    @FocusState private var replyFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resolved threads start folded to one line.
    ///
    /// A resolved thread is a settled argument. Left open it costs the same
    /// screen as a live one — the bot comment and the four-paragraph reply in
    /// the screenshot are a finished conversation pushing the unresolved
    /// threads below the fold. `nil` means "not yet touched by the reviewer",
    /// so a thread that resolves while they are reading it does not collapse
    /// under them.
    private var expanded: Bool { isExpanded ?? !thread.isResolved }

    private var isReplying: Bool { model.pendingReplyThreadIds.contains(thread.rootId) }
    private var isResolving: Bool { model.pendingResolveThreadIds.contains(thread.rootId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                        CommentRow(comment: comment, isReply: index > 0)
                    }
                }
                replyComposer
            } else {
                summary
            }
        }
        .motion(Motion.snappy, value: expanded)
        .padding(10)
        .reviewrrCard()
        // A resolved thread visibly settles — dims and eases back a touch —
        // so working through a list of threads reads as the queue actually
        // shrinking, not just a badge flipping silently.
        .opacity(thread.isResolved ? 0.72 : 1)
        .scaleEffect(thread.isResolved ? 0.985 : 1)
        .motion(Motion.smooth, value: thread.isResolved)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.snappy) { isExpanded = !expanded }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse this thread" : "Expand this thread")
            .accessibilityLabel(expanded ? "Collapse this thread" : "Expand this thread")

            location
                .layoutPriority(1)

            Spacer(minLength: 4)

            // "Outdated" already says the position is stale, so the old
            // "Unanchored thread" label beside it was saying the same thing
            // twice — in a 400pt column that had to wrap onto two lines.
            if thread.isOutdated {
                StatusChip(text: "Outdated", systemImage: "clock.arrow.circlepath", palette: .neutral)
            }
            switch thread.resolution {
            case .resolved:
                StatusChip(text: "Resolved", systemImage: "checkmark.circle.fill", palette: .green)
            case .unresolved:
                EmptyView()
            case .unknown:
                StatusChip(text: "Unknown", systemImage: "questionmark.circle", palette: .neutral)
            }

            resolveButton
        }
    }

    /// Where the thread is attached, or an honest statement that it isn't.
    ///
    /// The old label was "Unanchored thread", which is the data model's word,
    /// not a reviewer's: it covers three different situations — the lines
    /// moved, GitHub returned no path, or it returned no line — and told the
    /// reviewer none of them.
    @ViewBuilder
    private var location: some View {
        if let line = thread.line, !thread.path.isEmpty {
            Button {
                onNavigate(thread.path, line, thread.side ?? .right)
            } label: {
                Label("\(shortPath(thread.path)):\(line)", systemImage: "doc.text")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .buttonStyle(.reviewrrGhost)
            .controlSize(.small)
            .help("Jump to \(thread.path) line \(line)")
            .accessibilityLabel("Jump to \(thread.path) line \(line)")
        } else if !thread.path.isEmpty {
            Label(shortPath(thread.path), systemImage: "doc.text")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help("\(thread.path) — GitHub no longer reports which line this thread is on, so there is nowhere to jump to")
        } else {
            Label("Not on a line", systemImage: "text.bubble")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("A comment on the pull request rather than on a line of the diff")
        }
    }

    /// What a folded thread says: who is in it, how long it is, and the first
    /// line of what was said — enough to decide whether to open it.
    private var summary: some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.snappy) { isExpanded = true }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Expand this thread")
        .accessibilityLabel("Expand this thread: \(summaryText)")
    }

    private var summaryText: String {
        let replies = max(0, thread.comments.count - 1)
        let author = thread.comments.first?.author.login ?? "someone"
        let first = thread.comments.first?.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let count = replies == 0 ? "" : " · \(replies) repl\(replies == 1 ? "y" : "ies")"
        return "\(author)\(count) — \(first)"
    }

    private var resolveButton: some View {
        Button {
            Task { await model.setResolved(!thread.isResolved, threadRootId: thread.rootId) }
        } label: {
            if isResolving {
                ProgressView().controlSize(.small)
            } else {
                // A glyph, not a word: "Unresolve" plus two status chips plus
                // a path did not fit the rail's width, and the button was the
                // thing that got clipped off the right edge.
                Image(systemName: thread.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.system(size: 12))
            }
        }
        .buttonStyle(.reviewrrGhost)
        .controlSize(.small)
        .disabled(isResolving || thread.resolution == .unknown)
        .help(thread.resolution == .unknown
              ? "GitHub's resolution state for this thread isn't available right now"
              : (thread.isResolved ? "Reopen this thread on GitHub" : "Mark this thread resolved on GitHub"))
        .accessibilityLabel(thread.isResolved ? "Mark thread unresolved" : "Mark thread resolved")
    }

    /// Collapsed to a single ghost button until tapped — showing a full
    /// composer under every thread, all the time, is exactly the "wall of
    /// text" this pass is meant to undo. Expanding is `Motion.snappy`,
    /// matching every other direct-manipulation disclosure in the app.
    @ViewBuilder
    private var replyComposer: some View {
        Group {
            if composerExpanded {
                expandedComposer
            } else {
                Button {
                    composerExpanded = true
                    replyFocused = true
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
            }
        }
        .padding(.leading, 28)
        .motion(Motion.snappy, value: composerExpanded)
    }

    private var expandedComposer: some View {
        // The same shell as the assistant's composer and the inline draft
        // box, in the accent rather than AI purple: this reply goes to
        // GitHub under the reviewer's own name.
        ComposerShell(
            placeholder: "",
            tint: Theme.accent,
            isFocused: replyFocused,
            minHeight: 44
        ) {
            AnyView(
                ZStack(alignment: .topLeading) {
                    TextField("", text: $replyText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($replyFocused)
                        .accessibilityLabel("Reply to thread")
                    if replyText.isEmpty {
                        ComposerShell<EmptyView, EmptyView>.placeholderText("Reply — ⌘⏎ to send")
                    }
                }
            )
        } chips: {
            ComposerChip(systemImage: "arrowshape.turn.up.left") {
                Text("Posts to GitHub")
            }
            .help("A reply is published immediately, unlike an inline draft comment")
        } action: {
            HStack(spacing: Theme.Space.xs) {
                Button("Cancel") {
                    replyText = ""
                    composerExpanded = false
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
                .help("Discard this reply")
                .accessibilityLabel("Discard this reply")

                ComposerSendButton(
                    tint: Theme.accent,
                    isBusy: isReplying,
                    isEnabled: !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    sendHelp: "Send this reply to GitHub (⌘⏎)",
                    busyHelp: "Sending…",
                    onSend: sendReply
                )
            }
        }
        .padding(.bottom, 8)
    }

    private func sendReply() {
        let body = replyText
        replyText = ""
        composerExpanded = false
        Task { await model.reply(to: thread.rootId, body: body) }
    }

    private func shortPath(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// One comment row inside a thread card; replies are indented under the
/// root so the reply chain reads visually distinct from the original.
private struct CommentRow: View {
    let comment: ConversationComment
    let isReply: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(urlString: comment.author.avatarUrl, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.author.login).font(.caption.weight(.semibold))
                    Text(comment.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let url = URL(string: comment.url) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .help("Open this comment on GitHub")
                        .accessibilityLabel("Open comment on GitHub")
                    }
                }
                MarkdownText(text: comment.body)
                    .font(.callout)
            }
        }
        .padding(.leading, isReply ? 20 : 0)
        // Not `.combine`: the row carries a link out to GitHub, and
        // flattening the row takes that link with it.
        .accessibilityElement(children: .contain)
    }
}
