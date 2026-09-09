import SwiftUI

struct SubmitReviewButton: View {
    @EnvironmentObject var model: AppModel

    private var pendingCount: Int { model.draft.comments.count }

    var body: some View {
        Button {
            model.isSubmitFormPresented = true
        } label: {
            // The count rides on the button, so the toolbar says how much is
            // waiting without opening anything. This is the one number a
            // reviewer mid-review keeps checking.
            Label {
                if pendingCount > 0 {
                    Text("Submit review (\(pendingCount))")
                } else {
                    Text("Submit review")
                }
            } icon: {
                Image(systemName: "paperplane.fill")
            }
        }
        .help(model.draft.comments.isEmpty && model.draft.summary.isEmpty
              ? "Submit a review — add a summary or an inline comment first"
              : "Submit \(pendingCount) draft comment\(pendingCount == 1 ? "" : "s") (⌘⏎)")
        .accessibilityLabel("Submit review")
        // A popover anchored to this button, not a sheet over the window.
        //
        // A sheet was the wrong component for it: submitting a review is a
        // short form *about* the diff behind it, and a modal sheet dimmed
        // and detached the one thing a reviewer wants to glance at while
        // writing the summary — the code they are describing. A popover
        // hangs off the control that opened it, leaves the workspace
        // visible and interactive, and dismisses on Esc or a click outside
        // with the draft intact, which is what "Keep Draft" was there to do.
        //
        // Presentation state still lives on the model rather than in this
        // button, so the command palette and the menu bar open the same
        // popover.
        .popover(
            isPresented: $model.isSubmitFormPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            SubmitReviewForm(isPresented: $model.isSubmitFormPresented)
                .environmentObject(model)
        }
    }
}

/// The review-submission form.
///
/// Still named for what it is rather than how it is shown — it was a sheet,
/// it is now a popover, and it would work in either.
struct SubmitReviewForm: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    @FocusState private var summaryFocused: Bool
    @State private var showsComments = false

    /// The summary being typed, before it reaches the draft.
    ///
    /// `$model.draft.summary` bound straight to the editor meant every
    /// character republished `AppModel` — which re-rendered the whole
    /// window, diff pane included, behind this popover — and marked the
    /// draft dirty, which used to write it to disk. The commit is debounced,
    /// and forced before anything that reads the draft back.
    @State private var summary = ""
    @State private var summaryCommit: Task<Void, Never>?

    private var disabledReason: String? {
        guard summary.isEmpty && model.draft.comments.isEmpty else { return nil }
        return "Add a summary or an inline comment first."
    }

    /// Pushes the typed summary into the draft now. Called before submitting
    /// and when the form goes away, so no path can read a stale draft.
    private func commitSummary() {
        summaryCommit?.cancel()
        summaryCommit = nil
        if model.draft.summary != summary { model.draft.summary = summary }
    }

    private var pendingCount: Int { model.draft.comments.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    eventPicker
                    summaryField
                    if pendingCount > 0 { commentList }
                    warnings
                }
                .padding(Theme.Space.l)
            }
            // The form is short by design; the scroll view only earns its
            // keep when the comment list is expanded.
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .frame(width: 460)
        .task {
            // Whatever was typed before the form was last dismissed.
            summary = model.draft.summary
            // Focus the summary on open: the reviewer pressed a button
            // labelled "Submit review" and the next thing they do is type.
            summaryFocused = true
        }
        // Dismissing without submitting must not discard the summary, so the
        // debounce is flushed rather than cancelled on the way out.
        .onDisappear { commitSummary() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Submit review")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            // Which pull request this is going to. A popover can be opened
            // from a toolbar, a menu or ⌘K, and "submit to where" is worth
            // one line of confirmation before an irreversible action.
            if let reference = model.reference {
                Text(verbatim: "\(reference.owner)/\(reference.repo) #\(reference.number)")
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    // MARK: - Event

    private var eventPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Review type", selection: $model.draft.event) {
                ForEach(ReviewEvent.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Tints the selection to the meaning of the choice. The app's
            // accent is green, so a selected "Comment" segment was filled
            // the same green as "Approve" — the control looked like it was
            // approving whatever was selected.
            .tint(eventColor)
            .accessibilityLabel("Review type")

            eventDescription
        }
    }

    /// A plain segmented control doesn't carry approve/request-changes
    /// weight on its own; this line spells out what pressing the button will
    /// actually do, coloured to match.
    private var eventDescription: some View {
        Label(eventCopy.text, systemImage: eventCopy.icon)
            .font(.caption)
            .foregroundStyle(eventCopy.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var eventCopy: (icon: String, text: String, color: Color) {
        switch model.draft.event {
        case .comment:
            return ("bubble.left", "Leaves feedback without approving or blocking.", .secondary)
        case .approve:
            return ("checkmark.seal.fill", "Approves the pull request as ready to merge.", .green)
        case .requestChanges:
            return ("exclamationmark.triangle.fill", "Blocks merging until changes are made.", .red)
        }
    }

    private var eventColor: Color {
        switch model.draft.event {
        case .comment: return .secondary
        case .approve: return .green
        case .requestChanges: return .red
        }
    }

    // MARK: - Summary

    private var summaryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.draft.event == .comment && pendingCount == 0 ? "Required" : "Optional")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $summary)
                    .font(.callout)
                    .focused($summaryFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    // 110, not 300. The old form gave this a `minHeight` of
                    // 100 inside a container that stretched it to the height
                    // of the window — most of the dialog was an unlabelled
                    // grey void with no placeholder, which read as broken
                    // rather than as a field waiting for text.
                    .frame(height: 110)

                if summary.isEmpty {
                    Text("What should the author know? Markdown is supported.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                    .strokeBorder(summaryFocused ? Theme.accent.opacity(0.6) : Theme.hairline)
            )
            .onChange(of: summary) { _, _ in
                summaryCommit?.cancel()
                summaryCommit = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    commitSummary()
                }
            }
        }
    }

    // MARK: - Inline comments

    /// What is actually being sent, collapsed by default.
    ///
    /// The count is the headline — a reviewer who has been drafting for
    /// twenty minutes wants to confirm the number before an irreversible
    /// send — and the list is there to check, not to read, so it does not
    /// take up room until asked for.
    private var commentList: some View {
        DisclosureGroup(isExpanded: $showsComments) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(model.draft.comments) { comment in
                    Button {
                        // Jumping to the line closes nothing: the popover
                        // stays, the pane moves behind it. That is the whole
                        // advantage of not being a modal sheet.
                        model.workspace.jump(to: comment.path, line: comment.line, side: comment.side)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\((comment.path as NSString).lastPathComponent) · \(comment.rangeDescription)")
                                .font(Theme.monoFontSmall)
                                .foregroundStyle(.secondary)
                            Text(comment.body)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this comment in the diff")
                }
            }
            .padding(.top, Theme.Space.s)
        } label: {
            Text("\(pendingCount) inline comment\(pendingCount == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warnings: some View {
        if let staleHeadWarning {
            Label(staleHeadWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let submitError = model.submitError {
            Label(submitError, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var staleHeadWarning: String? {
        guard let pr = model.pullRequest else { return nil }
        let stale = model.draft.comments.contains { $0.headSha != pr.headSha }
        return stale ? "Some drafts were written against an earlier revision. Submitting will refresh anchors." : nil
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            // Draft status belongs here, beside the button that keeps it —
            // not leading the form, where it was the first thing read and
            // answered a question nobody had yet asked.
            if let error = model.draftSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let reason = disabledReason, model.submitError == nil {
                // The reason the button is dead, next to the button, rather
                // than as a paragraph 60pt above it.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Draft saved on this Mac", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Theme.Space.s)

            Button("Keep Draft") { isPresented = false }
                .buttonStyle(.bordered)
                // Esc, the standard dismiss. It was bound to a bare "." —
                // no modifier — so typing a period anywhere the text editor
                // did not have focus closed the sheet.
                .keyboardShortcut(.cancelAction)
                .help("Close without submitting; the draft is kept (Esc)")
                .accessibilityLabel("Keep the draft and close")

            Button {
                // The debounce must not be in flight when the review is
                // built: a summary typed and submitted inside 250ms would
                // otherwise go to GitHub without it.
                commitSummary()
                Task {
                    await model.submitReview()
                    guard model.submitError == nil else { return }
                    // Submitting empties the draft's summary. Without
                    // clearing the local copy too, `onDisappear` would
                    // commit it straight back and the review just sent
                    // would reappear as an unsent draft.
                    summary = ""
                    isPresented = false
                }
            } label: {
                if model.isSubmittingReview {
                    ProgressView().controlSize(.small)
                } else {
                    // The verb, not "Submit". The segmented control above
                    // decides whether this approves or blocks a merge, and
                    // a button reading "Submit" left that decision legible
                    // only in the control the reviewer had already stopped
                    // looking at.
                    Text(model.draft.event.label)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.draft.event == .requestChanges ? .red : Theme.accent)
            // ⌘Return, not Return: the summary field above is a multi-line
            // editor, and Return there has to insert a line rather than send
            // the review to GitHub.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isSubmittingReview || disabledReason != nil)
            .help(disabledReason ?? "\(model.draft.event.label) this pull request (⌘⏎)")
            .accessibilityLabel("\(model.draft.event.label) this pull request")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}
