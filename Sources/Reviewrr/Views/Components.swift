import AppKit
import SwiftUI

struct StatusPill: View {
    let pr: PullRequest

    private var label: String {
        if pr.merged { return "Merged" }
        if pr.state == .closed { return "Closed" }
        if pr.draft { return "Draft" }
        return "Open"
    }

    private var color: Color {
        if pr.merged { return .purple }
        if pr.state == .closed { return .red }
        if pr.draft { return .secondary }
        return .green
    }

    /// Shares the app's one pill shape (`Theme.chip*`) with category chips
    /// and GitHub labels: three kinds of badge sit in the same rows, and a
    /// point of padding or a step of tint between them read as three
    /// different kinds of object rather than three of the same.
    var body: some View {
        Label(label, systemImage: "arrow.triangle.pull")
            .font(Theme.captionEmphasis)
            .padding(.horizontal, Theme.chipPaddingHorizontal)
            .padding(.vertical, Theme.chipPaddingVertical)
            .background(color.opacity(Theme.chipFillOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(Theme.chipStrokeOpacity), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// `Theme.addedText`/`removedText` (Design/Theme.swift) are light pastels
/// tuned to sit on a dark canvas; at those RGB values they under-contrast
/// against a light-mode list or card background. `Theme.swift` is a shared
/// contract this track doesn't own, so status colour anywhere in the
/// workspace routes through this appearance-aware pair instead — matching
/// the plain `.green`/`.red` `StatusPill` (above) already uses for the same
/// add/remove meaning.
enum DiffTextColor {
    static func added(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? .green : Theme.addedText
    }
    static func removed(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? .red : Theme.removedText
    }
}

struct FileStatusIcon: View {
    let status: PRFileStatus
    @Environment(\.colorScheme) private var colorScheme

    private var glyph: String {
        switch status {
        case .added: return "plus"
        case .removed: return "minus"
        case .modified, .changed: return "pencil"
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .unchanged: return "equal"
        }
    }

    private var color: Color {
        switch status {
        case .added: return DiffTextColor.added(colorScheme)
        case .removed: return DiffTextColor.removed(colorScheme)
        default: return .secondary
        }
    }

    var body: some View {
        Image(systemName: glyph)
            .font(.system(size: Theme.iconSmallSize, weight: .bold))
            .foregroundStyle(color)
            .frame(width: Theme.glyphColumn, height: Theme.glyphColumn)
    }
}

struct DiffStatCounts: View {
    let additions: Int
    let deletions: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if additions > 0 {
                Text("+\(additions)").foregroundStyle(DiffTextColor.added(colorScheme))
            }
            if deletions > 0 {
                Text("-\(deletions)").foregroundStyle(DiffTextColor.removed(colorScheme))
            }
        }
        .font(Theme.monoFontSmall)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    /// The block centres in whatever panel hosts it but keeps its text
    /// column capped: a sentence of explanation set across a 900pt diff pane
    /// is one line the eye has to track, not a paragraph.
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 320)
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity)
    }
}

/// A `FileCategory` badge. Pass `action` to make it an interactive toggle
/// (the file-tree filter bar) — it adopts the shared `.reviewrrChip` button
/// style so every selectable pill in the app presses and hovers the same
/// way. Omit `action` for a plain, non-interactive chip (the diff pane's
/// sticky per-file header).
struct CategoryChip: View {
    let category: FileCategory
    var count: Int? = nil
    var isHidden: Bool = false
    var action: (() -> Void)? = nil

    private var label: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: category.symbolName)
                .symbolRenderingMode(.hierarchical)
            Text(category.label)
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.reviewrrChip(selected: !isHidden, tint: category.tint))
                    .help(isHidden ? "Show \(category.label.lowercased()) files" : "Hide \(category.label.lowercased()) files")
            } else {
                label
                    .font(Theme.captionEmphasis)
                    .padding(.horizontal, Theme.chipPaddingHorizontal)
                    .padding(.vertical, Theme.chipPaddingVertical)
                    .background(category.tint.opacity(Theme.chipFillOpacity), in: Capsule())
                    .overlay(Capsule().strokeBorder(category.tint.opacity(Theme.chipStrokeOpacity), lineWidth: 1))
                    .foregroundStyle(category.tint)
            }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }

    private var accessibilityText: String {
        var text = category.label
        if let count { text += ", \(count) files" }
        if isHidden { text += ", hidden" }
        return text
    }
}

/// The mark-viewed glyph shared by the file tree row and the diff pane's
/// sticky file header. The bounce reads as "I just did that" without
/// turning review progress into a game — see `ReviewProgressFooter`.
struct ViewedGlyph: View {
    let viewed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let icon = Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.hierarchical)
        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.bounce, value: viewed)
        }
    }
}

// MARK: - Avatars

/// A GitHub user's avatar: a circle that fills in once the image loads, and
/// a neutral placeholder while it's in flight or absent. Several tracks
/// independently built this exact `AsyncImage` + `Circle` placeholder pair
/// for review threads, comments, reviews, and the PR header's author and
/// reviewer avatars — consolidated here since they render identically.
/// Decorative by default (`accessibilityHidden`): the surrounding row
/// already names the person in text, so the picture itself carries no
/// information VoiceOver needs to announce separately.
struct AvatarView: View {
    let urlString: String?
    var size: CGFloat = 18

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { image in
            image.resizable()
        } placeholder: {
            Circle().fill(Color.secondary.opacity(0.2))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Builds the GitHub web URL for a file at the PR's current head commit —
/// used by the "Open on GitHub" context menu action in both the file tree
/// and the diff pane's sticky header. Enterprise-aware via
/// `settings.githubHost`, the same host every other GitHub link in the app
/// already goes through.
@MainActor
func githubBlobURL(model: AppModel, path: String) -> URL? {
    guard let reference = model.reference, let sha = model.pullRequest?.headSha else { return nil }
    return model.settings.githubHost.webBaseURL
        .appendingPathComponent(reference.owner)
        .appendingPathComponent(reference.repo)
        .appendingPathComponent("blob")
        .appendingPathComponent(sha)
        .appendingPathComponent(path)
}

// MARK: - GitHub labels

/// One GitHub label, in GitHub's own colour.
///
/// A label is a repository's own vocabulary — "needs-qa", "breaking" — so it
/// keeps the exact colour the repo assigned it in both appearances, the same
/// as on github.com, rather than being re-tinted into Reviewrr's palette.
/// The tooltip carries the full name because a long label truncates in a
/// sidebar column.
struct GitHubLabelChip: View {
    let label: GitHubLabel

    var body: some View {
        let color = Color(githubHex: label.color)
        Text(label.name)
            .font(Theme.captionEmphasis)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Theme.chipPaddingHorizontal)
            .padding(.vertical, Theme.chipPaddingVertical)
            .background(color.opacity(Theme.chipFillOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(Theme.chipStrokeOpacity), lineWidth: 1))
            .foregroundStyle(color)
            .help("Label: \(label.name)")
            .accessibilityLabel("Label: \(label.name)")
    }
}

/// A wrapping row of labels, capped so a heavily-labelled PR cannot push the
/// file tree off screen; the remainder is one click away.
struct GitHubLabelRow: View {
    let labels: [GitHubLabel]
    var collapsedLimit: Int = 4
    @State private var expanded = false

    private var visible: [GitHubLabel] {
        expanded ? labels : Array(labels.prefix(collapsedLimit))
    }

    var body: some View {
        if !labels.isEmpty {
            FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                ForEach(visible) { GitHubLabelChip(label: $0) }
                if labels.count > collapsedLimit {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded ? "Show fewer" : "+\(labels.count - collapsedLimit)")
                    }
                    .buttonStyle(.reviewrrChip(selected: false))
                    .help(expanded ? "Show fewer labels" : "Show \(labels.count - collapsedLimit) more labels")
                    .accessibilityLabel(expanded ? "Show fewer labels" : "Show \(labels.count - collapsedLimit) more labels")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(Motion.smooth, value: expanded)
        }
    }
}

extension Color {
    /// GitHub returns label colors as a bare 6-digit hex string (no `#`).
    /// Rendered from the raw value directly rather than a semantic token,
    /// deliberately — a label keeps its exact GitHub color in both light
    /// and dark mode, the same as on github.com.
    init(githubHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Copyable values

/// A short value — a branch name, a SHA, a reference — carrying the whole Mac
/// vocabulary for "I want this on my clipboard".
///
/// macOS offers several affordances for this and they are not alternatives:
/// a reviewer reaches for whichever one they already trust. So this provides
/// all of them at once rather than picking one:
///
/// - **Click** it. The fastest path, and the one a hover highlight advertises.
/// - **Right-click** it for a menu, which is where a Mac user looks first and
///   the only place extra actions can live (a `git switch` line, say).
/// - **Select the text** and press ⌘C, which is what someone who does not
///   believe the value is a control will try.
/// - **Drag** it into another window. A native app lets a value be dragged;
///   a web page usually cannot, which is exactly why it feels like a Mac app
///   when it works.
///
/// Confirmation is a glyph swap for a beat, not a banner: the clipboard has
/// no visible state, so a copy with no acknowledgement leaves the reviewer
/// pressing ⌘V somewhere else to find out whether it worked.
struct CopyableText: View {
    let text: String
    /// What the value is, for the tooltip, the menu item and VoiceOver —
    /// "branch name", not "text".
    let name: String
    var font: Font = Theme.caption
    var color: Color = .primary
    /// Extra menu entries as (title, value to copy) — e.g. a checkout command.
    var extraActions: [(title: String, value: String)] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var confirmationTask: Task<Void, Never>?

    var body: some View {
        Button {
            copy(text)
        } label: {
            HStack(spacing: 3) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .opacity(copied || hovering ? 1 : 0)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? Theme.controlFill : .clear)
        )
        .motion(Motion.hover, value: hovering)
        .motion(Motion.snappy, value: copied)
        // Selection is deliberately still available: someone who does not
        // read this as a button will try to select and ⌘C.
        .textSelection(.enabled)
        .onDrag { NSItemProvider(object: text as NSString) }
        .contextMenu {
            Button("Copy \(name)") { copy(text) }
            ForEach(extraActions, id: \.title) { action in
                Button(action.title) { copy(action.value) }
            }
        }
        .help(copied ? "Copied" : "\(text) — click to copy the \(name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(text)")
        .accessibilityHint("Copies the \(name)")
        .accessibilityAddTraits(.isButton)
    }

    @State private var hovering = false

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        confirmationTask?.cancel()
        copied = true
        confirmationTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
