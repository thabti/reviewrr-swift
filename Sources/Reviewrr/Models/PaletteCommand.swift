import Foundation

/// One entry in the ⌘K palette.
///
/// Commands are values, not view code: the palette can then be ranked,
/// filtered, and unit-tested without a window, and any part of the app can
/// contribute entries without knowing how the palette is drawn.
struct PaletteCommand: Identifiable {
    enum Group: String, CaseIterable {
        case go = "Go"
        case pullRequest = "Pull request"
        case files = "Files"
        case inbox = "Inbox"
        case projects = "Projects"
        case ai = "AI"
        case view = "View"
        case app = "App"

        /// Group order in the palette when no query narrows it — the order a
        /// reviewer is most likely to want, not alphabetical.
        var rank: Int { Group.allCases.firstIndex(of: self) ?? 0 }
    }

    let id: String
    let title: String
    var subtitle: String?
    var symbol: String
    var group: Group
    /// Rendered right-aligned, e.g. "⌘R". Display only — the real binding
    /// lives on the menu item or view that owns it.
    var shortcut: String?
    /// Extra terms that should match this command without appearing in its
    /// title: synonyms, and the vocabulary someone might type instead
    /// ("theme" for appearance, "diff" for the file list).
    var keywords: [String] = []
    var isEnabled: Bool = true

    let run: @MainActor () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        group: Group,
        shortcut: String? = nil,
        keywords: [String] = [],
        isEnabled: Bool = true,
        run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.group = group
        self.shortcut = shortcut
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.run = run
    }
}
