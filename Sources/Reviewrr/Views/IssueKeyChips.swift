import AppKit
import SwiftUI

/// The tracker configuration, published once by the root view so a chip
/// anywhere in the app can build a link without holding `AppModel`.
///
/// The same shape as `openSettingsPane`: the inbox row, the PR header and the
/// Markdown renderer all want it, none of them should own it, and a preview
/// that has never heard of Jira still renders — the default is disabled, and
/// a disabled tracker produces no chips at all.
private struct IssueTrackerKey: EnvironmentKey {
    static let defaultValue = IssueTrackerSettings()
}

extension EnvironmentValues {
    var issueTracker: IssueTrackerSettings {
        get { self[IssueTrackerKey.self] }
        set { self[IssueTrackerKey.self] = newValue }
    }
}

/// The issue keys found in a pull request, as links out to the tracker.
///
/// Nothing at all when the tracker is off, unconfigured, or the pull request
/// mentions no issue: an empty row of chrome that says "no issues found" is
/// worse than silence, because every pull request that legitimately has none
/// would carry it.
struct IssueKeyChips: View {
    let title: String?
    /// The pull request's description. Named `description` rather than `body`
    /// because a `View` already has a `body`.
    let description: String?
    let branch: String?
    /// A single line beside other chrome, or wrapped across the width.
    var wraps = true

    @Environment(\.issueTracker) private var tracker
    @Environment(\.openURL) private var openURL

    private var references: [IssueReference] {
        guard tracker.isUsable else { return [] }
        return IssueKeyDetector(settings: tracker).keys(title: title, body: description, branch: branch)
    }

    var body: some View {
        let references = self.references
        if !references.isEmpty {
            if wraps {
                // `ViewThatFits` rather than a flow layout: one line while it
                // fits, and a wrapped column when the panel is narrow. Six
                // keys in a 320pt rail otherwise clip the last three.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.xs) { chips(references) }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) { chips(references) }
                }
            } else {
                HStack(spacing: Theme.Space.xs) { chips(references) }
            }
        }
    }

    @ViewBuilder
    private func chips(_ references: [IssueReference]) -> some View {
        ForEach(references) { reference in
            IssueKeyChip(reference: reference, url: tracker.url(for: reference.key))
        }
    }
}

/// One key, as a link.
struct IssueKeyChip: View {
    let reference: IssueReference
    let url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url else { return }
            openURL(url)
        } label: {
            Label(reference.key, systemImage: "arrow.up.forward.square")
                .labelStyle(.titleAndIcon)
                .font(Theme.captionEmphasis)
                .padding(.horizontal, Theme.chipPaddingHorizontal)
                .padding(.vertical, Theme.chipPaddingVertical)
                .background(Theme.accent.opacity(Theme.chipFillOpacity), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url.map { "Open \(reference.key) in Jira — \($0.absoluteString)" } ?? reference.key)
        .accessibilityLabel("Open issue \(reference.key) in Jira")
        .contextMenu {
            if let url {
                Button("Open in Jira") { openURL(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reference.key, forType: .string)
            }
        }
    }
}
