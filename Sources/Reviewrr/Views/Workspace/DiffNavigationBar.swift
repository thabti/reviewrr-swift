import SwiftUI

/// The diff's navigation controls, floating over the bottom of the pane.
///
/// They used to live in the bar across the top, beside the split/unified
/// picker — which put the two things a reviewer presses constantly, file by
/// file and change by change, as far from the code as the window allows, and
/// mixed them in with a control that is set once and forgotten.
///
/// Floating at the bottom centre puts them where the hand already is and
/// where the eye already ends up. The pane reserves the bar's height as
/// bottom padding, so the last line of a file can still be scrolled clear of
/// it: the bar may pass over code on the way there, but nothing is
/// permanently hidden underneath it.
///
/// ## Why each group is labelled
///
/// Three pairs of arrows in a row is three pairs of arrows: the first
/// version distinguished them only by symbol shape (chevrons for files,
/// `arrow.*.to.line` for changes), and `arrow.down.to.line` means "go to the
/// end" everywhere else in the system, not "go to the next one". Each group
/// now opens with a small, non-interactive glyph naming what its arrows
/// step through, so the arrows themselves can be the same plain chevrons in
/// every group and still be unambiguous.
struct DiffNavigationBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var workspace: WorkspaceModel

    /// What the pane adds as bottom content inset so the bar never sits
    /// permanently on top of the last lines of a file.
    static let reservedHeight: CGFloat = 64

    private func hunks(in path: String) -> [DiffHunk] {
        model.parsedFiles[path]?.hunks ?? []
    }

    private var currentHunks: [DiffHunk] {
        guard let filename = model.selectedFile else { return [] }
        return hunks(in: filename)
    }

    /// Every published thread and unsent draft that has a line, in the order
    /// a reviewer would meet them reading downwards.
    ///
    /// Memoized in `WorkspaceModel` rather than rebuilt here. This bar holds
    /// an `@EnvironmentObject` on `AppModel`, so *any* change to the model —
    /// a keystroke in a composer, a viewed-file toggle — re-evaluates this
    /// body; mapping every thread and draft in the pull request each time
    /// was work proportional to the conversation on a view that only needs a
    /// count and a cursor.
    private var commentAnchors: [DiffAnchor] {
        workspace.commentAnchors(threads: model.threads, drafts: model.draft.comments)
    }

    private var commentCount: Int { commentAnchors.count }

    private var isCurrentFileViewed: Bool {
        guard let filename = model.selectedFile else { return false }
        return model.draft.viewedFiles.contains(filename)
    }

    /// How far through the file list this reviewer is, so the tick says
    /// what marking it does to the review as a whole.
    private var viewedProgress: (viewed: Int, total: Int) {
        let paths = workspace.orderedVisiblePaths
        let viewed = paths.filter { model.draft.viewedFiles.contains($0) }.count
        return (viewed, paths.count)
    }

    /// How many changes this file has, and which one the cursor is on — the
    /// same information the comment group's count gives, for the control a
    /// reviewer presses most.
    private var changePosition: (index: Int, total: Int)? {
        guard let filename = model.selectedFile else { return nil }
        let anchors = DiffNavigator.changeAnchors(in: currentHunks, path: filename)
        guard !anchors.isEmpty else { return nil }
        guard let cursor = workspace.hunkCursor[filename],
              let index = anchors.firstIndex(where: { $0.line == cursor })
        else { return (0, anchors.count) }
        return (index + 1, anchors.count)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // First in the bar, and on its own: marking a file viewed is the
            // gesture that *ends* work on a file, and it belongs next to the
            // arrows that leave it. It is also the only control here that
            // changes the review rather than the viewport, which is why it
            // is separated from the three stepping groups.
            viewedToggle
            divider
            group("doc.text", label: "Files") {
                navButton("chevron.up", "Previous file (k)") { moveFile(-1) }
                navButton("chevron.down", "Next file (j)") { moveFile(1) }
            }
            divider
            group("plus.forwardslash.minus", label: "Changes") {
                navButton("chevron.up", "Previous change (p)") { moveHunk(-1) }
                if let position = changePosition {
                    counter(
                        "\(position.index)/\(position.total)",
                        muted: false,
                        help: "Change \(position.index) of \(position.total) in this file"
                    )
                }
                navButton("chevron.down", "Next change (n)") { moveHunk(1) }
            }
            divider
            group("bubble.left.and.bubble.right", label: "Comments") {
                navButton("chevron.up", "Previous comment", disabled: commentCount == 0) { moveComment(-1) }
                // The count is the point: it says whether pressing the
                // arrows will do anything, and how much there is to work
                // through, without opening the conversation panel.
                counter(
                    "\(commentCount)",
                    muted: commentCount == 0,
                    help: "\(commentCount) comment\(commentCount == 1 ? "" : "s") and draft\(commentCount == 1 ? "" : "s") on this pull request"
                )
                navButton("chevron.down", "Next comment", disabled: commentCount == 0) { moveComment(1) }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 7)
        // `.thickMaterial`, not `.regular`: this sits over syntax-coloured
        // code, and at regular thickness the diff's greens and reds bled
        // through the dock and fought its own controls.
        .background(.thickMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                // A top-lit edge, so the capsule reads as a raised object
                // rather than a flat pill drawn on the code.
                LinearGradient(
                    colors: [Color.white.opacity(0.16), Theme.hairline],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
        // Two shadows: a tight contact shadow that anchors it to the pane,
        // and a wide soft one that lifts it. One shadow can do either, not
        // both, and a single 12pt blur read as a smudge under the capsule.
        .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.bottom, Theme.Space.m)
        .motion(Motion.smooth, value: commentCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diff navigation")
    }

    /// Mark the open file viewed, or un-mark it.
    ///
    /// A filled tick when the file is done, a hollow one when it is not —
    /// state a reviewer can read without hovering, and the same ⇧⌘V the
    /// menu bar binds. The count beside it is the review's progress, which
    /// is the reason to press it: 12/31 says how much is left.
    private var viewedToggle: some View {
        HStack(spacing: 4) {
            Button {
                guard let filename = model.selectedFile else { return }
                model.toggleViewed(filename)
            } label: {
                Image(systemName: isCurrentFileViewed ? "checkmark.circle.fill" : "checkmark.circle")
                    .symbolRenderingMode(isCurrentFileViewed ? .palette : .hierarchical)
                    .foregroundStyle(isCurrentFileViewed ? Theme.addedText : .secondary, .clear)
                    .frame(width: 22, height: 20)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.reviewrrGhost)
            .controlSize(.small)
            .disabled(model.selectedFile == nil)
            .help(isCurrentFileViewed ? "Mark this file not viewed (⇧⌘V)" : "Mark this file viewed (⇧⌘V)")
            .accessibilityLabel(isCurrentFileViewed ? "Mark this file not viewed" : "Mark this file viewed")

            let progress = viewedProgress
            if progress.total > 0 {
                counter(
                    "\(progress.viewed)/\(progress.total)",
                    muted: progress.viewed == 0,
                    help: "\(progress.viewed) of \(progress.total) files marked viewed"
                )
            }
        }
        .motion(Motion.snappy, value: isCurrentFileViewed)
    }

    private func group<Content: View>(
        _ symbol: String, label: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .help(label)
                // Decoration for a sighted reader; the buttons carry their
                // own labels, so announcing this again is noise.
                .accessibilityHidden(true)
            content()
        }
    }

    private var divider: some View {
        Divider()
            .frame(height: 16)
            .accessibilityHidden(true)
    }

    private func counter(_ text: String, muted: Bool, help: String) -> some View {
        Text(text)
            .font(Theme.monoFontSmall)
            .foregroundStyle(muted ? .tertiary : .secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .frame(minWidth: 26)
            .help(help)
            .accessibilityLabel(help)
    }

    private func navButton(
        _ symbol: String,
        _ help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.reviewrrGhost)
        .controlSize(.small)
        .disabled(disabled)
        .help(disabled ? "No comments to move between" : help)
        .accessibilityLabel(help)
    }

    // MARK: - Movement

    func moveFile(_ delta: Int) {
        guard let next = DiffNavigator.adjacentFile(
            to: model.selectedFile, in: workspace.orderedVisiblePaths, delta: delta
        ) else { return }
        model.selectedFile = next
    }

    /// Both the `n`/`p` keys and these arrows go through
    /// `AppModel.stepChange`, so they cannot drift apart again — they used
    /// to disagree, with the keys falling through to the next file and the
    /// arrows doing nothing at the last change.
    func moveHunk(_ delta: Int) {
        Task { await model.stepChange(delta) }
    }

    func moveComment(_ delta: Int) {
        guard let target = workspace.advanceComment(anchors: commentAnchors, delta: delta) else { return }
        model.selectedFile = target.path
        workspace.jump(to: target.path, line: target.line, side: target.side)
    }
}
