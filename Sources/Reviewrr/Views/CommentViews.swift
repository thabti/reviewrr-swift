import SwiftUI

/// The container every inline discussion block sits in.
///
/// Three full-bleed washes used to do this job: 4% black for a published
/// thread, 5% for the composer, 8% accent for a draft. In light mode 4% and
/// 5% black are the same colour; in dark mode 4% white is invisible; and the
/// thread's 4% was also the split view's empty-half fill, so "someone
/// commented here" and "this side has no line" were the same rectangle. An
/// inset card with a hairline reads as an object *attached to* the line
/// rather than as a tint *of* it, and works in both appearances and both
/// diff layouts.
private struct InlineDiscussionCard: ViewModifier {
    /// The rail is unpublished work's own signal — a draft or a composer
    /// carries an accent edge, published discussion does not — so the two
    /// stay distinguishable at a glance without relying on a fill that is
    /// nearly invisible in one appearance or the other.
    var accented: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .padding(.leading, accented ? 3 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if accented { Rectangle().fill(Theme.accent).frame(width: 3) }
            }
            .reviewrrCard()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

private extension View {
    func inlineDiscussionCard(accented: Bool = false) -> some View {
        modifier(InlineDiscussionCard(accented: accented))
    }
}

/// Read-only render of an existing GitHub review thread, embedded inline
/// in Track C's diff view. GitHub remains the source of truth for
/// published discussion: this view never edits, replies to, or resolves
/// anything — those actions live in the Conversation panel
/// (`Views/Conversation/ConversationThreadCard.swift`), which has the
/// GraphQL-backed resolution state and node id this bare REST thread
/// doesn't carry.
struct ThreadView: View {
    let thread: ReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if thread.isOutdated {
                Label("Outdated", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("These lines changed after this thread was written")
                    .accessibilityLabel("Outdated thread — these lines changed after it was written")
            }
            ForEach(thread.comments) { comment in
                HStack(alignment: .top, spacing: 8) {
                    AvatarView(urlString: comment.user.avatarUrl, size: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(comment.user.login).font(.caption.weight(.semibold))
                            Text(comment.createdAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        MarkdownText(
                            text: comment.body,
                            languageHint: SyntaxHighlighter.language(forPath: comment.path)
                        )
                        .font(.callout)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .inlineDiscussionCard()
    }
}

struct DraftCommentRow: View {
    @EnvironmentObject var model: AppModel
    let comment: DraftComment
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Draft", systemImage: "pencil.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .help("A local draft — nothing is on GitHub until you submit the review")
                    .accessibilityLabel("Local draft comment, not yet submitted")
                Spacer()
                Button("Edit") { text = comment.body; editing = true }
                    .buttonStyle(.reviewrrGhost)
                    .controlSize(.small)
                    .help("Edit this draft comment")
                    .accessibilityLabel("Edit draft comment")
                Button("Delete", role: .destructive) { model.deleteDraftComment(comment.id) }
                    .buttonStyle(.reviewrrDestructive)
                    .controlSize(.small)
                    .help("Delete this draft comment — it was never sent to GitHub")
                    .accessibilityLabel("Delete draft comment")
            }
            if editing {
                TextEditor(text: Binding(
                    get: { model.draft.comments.first(where: { $0.id == comment.id })?.body ?? text },
                    set: { text = $0; model.updateDraftComment(comment.id, body: $0) }
                ))
                    .font(.callout)
                    .frame(minHeight: 50)
                    .padding(4)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Done") {
                        model.updateDraftComment(comment.id, body: text)
                        editing = false
                    }
                    .buttonStyle(.reviewrrPrimary)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                MarkdownText(text: comment.body)
                    .font(.callout)
            }
        }
        .inlineDiscussionCard(accented: true)
        .motion(Motion.snappy, value: editing)
    }
}

struct CommentComposer: View {
    @EnvironmentObject var model: AppModel
    let filename: String
    let line: Int
    let side: DiffSide
    let onDone: () -> Void
    @ObservedObject private var workspace = WorkspaceModel.shared
    @FocusState private var focused: Bool

    /// The text being typed, held locally so a keystroke re-renders this box
    /// and nothing else.
    ///
    /// It is mirrored into the workspace on every change, which is what
    /// keeps it: the composer lives inside the diff's lazy stack, so
    /// scrolling away — or anyone marking the file viewed — tears this view
    /// down, and the mirror is what `task(id:)` reads it back from. That
    /// write publishes nothing; the durable copy is written by
    /// `saveComposerDraft`, which coalesces its disk write.
    @State private var text = ""

    private var anchorKey: String {
        WorkspaceModel.composerKey(path: filename, line: line, side: side)
    }

    /// The selection this comment will carry, when the reviewer dragged the
    /// gutter across several lines rather than clicking one.
    /// Turns the typed text into an inline draft, carrying the dragged range
    /// when there is one.
    private func addComment() {
        let range = selectedRange
        model.addDraftComment(
            path: filename, line: range?.upperBound ?? line, side: side,
            body: text, startLine: range?.lowerBound
        )
        text = ""
        model.saveComposerDraft(path: filename, line: line, side: side, body: "")
        workspace.clearComposer(path: filename, line: line, side: side)
        workspace.clearLineSelection()
        onDone()
    }

    private var selectedRange: ClosedRange<Int>? {
        guard let selection = workspace.lineSelection,
              selection.path == filename, selection.side == side,
              selection.isMultiLine, selection.range.contains(line)
        else { return nil }
        return selection.range
    }

    private var anchorDescription: String {
        guard let range = selectedRange else { return "line \(line)" }
        return "lines \(range.lowerBound)–\(range.upperBound)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // What this comment will attach to, said out loud: a range picked
            // out by dragging is invisible once the composer covers the lines
            // it came from.
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: selectedRange == nil ? "arrow.turn.down.right" : "text.justify.left")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Commenting on \(anchorDescription)")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if selectedRange != nil {
                    Button("Just this line") { workspace.clearLineSelection() }
                        .buttonStyle(.reviewrrGhost)
                        .controlSize(.small)
                        .help("Attach the comment to line \(line) only")
                        .accessibilityLabel("Attach the comment to line \(line) only")
                }
            }

            // The same shell the assistant and the reply box wear, in the
            // accent: an inline comment is the reviewer's own draft, and
            // nothing they write should carry the colour this app reserves
            // for "a model said this".
            ComposerShell(
                placeholder: "",
                tint: Theme.accent,
                isFocused: focused,
                minHeight: 60
            ) {
                AnyView(
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .accessibilityLabel("Comment on \(anchorDescription)")
                        if text.isEmpty {
                            ComposerShell<EmptyView, EmptyView>.placeholderText(
                                "Comment on \(anchorDescription) — ⌘⏎ to add it as a draft"
                            )
                            .padding(.top, 2)
                        }
                    }
                )
            } chips: {
                ComposerChip(systemImage: selectedRange == nil ? "arrow.turn.down.right" : "text.justify.left") {
                    Text(anchorDescription)
                }
                .help("Where this comment will attach")

                if selectedRange != nil {
                    Button("Just this line") { workspace.clearLineSelection() }
                        .buttonStyle(.reviewrrGhost)
                        .controlSize(.small)
                        .help("Attach the comment to line \(line) only")
                        .accessibilityLabel("Attach the comment to line \(line) only")
                }
            } action: {
                HStack(spacing: Theme.Space.xs) {
                    Button("Cancel") {
                        // Cancel is the one place the text is deliberately
                        // discarded, so it is the one place that clears it.
                        text = ""
                        model.saveComposerDraft(path: filename, line: line, side: side, body: "")
                        workspace.clearComposer(path: filename, line: line, side: side)
                        workspace.clearLineSelection()
                        onDone()
                    }
                    .buttonStyle(.reviewrrGhost)
                    .controlSize(.small)
                    .help("Discard this comment")
                    .accessibilityLabel("Discard this comment")

                    ComposerSendButton(
                        tint: Theme.accent,
                        isEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        sendHelp: "Add as a draft comment (⌘⏎) — nothing reaches GitHub until you submit the review",
                        onSend: addComment
                    )
                }
            }
        }
        .inlineDiscussionCard(accented: true)
        // Reads back whatever was typed before this row was recycled, and
        // re-reads it if the composer is moved to another anchor.
        .task(id: anchorKey) {
            text = workspace.composerText(path: filename, line: line, side: side)
            focused = true
        }
        .onChange(of: text) { _, typed in
            // Mirrored immediately — a dictionary write that publishes
            // nothing, so no amount of typing can lose the text to a scroll.
            workspace.setComposerText(typed, path: filename, line: line, side: side)
            // And handed to the draft, which coalesces the disk write.
            model.saveComposerDraft(path: filename, line: line, side: side, body: typed)
        }
    }
}
