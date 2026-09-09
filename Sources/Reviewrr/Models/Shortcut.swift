import Foundation
import SwiftUI

/// Every keyboard binding the app installs, and the only place any of them
/// is described.
///
/// The keyboard is this app's whole point, and it used to be declared three
/// times over: the menu bar in `App/ReviewrrApp.swift`, the `shortcut:`
/// strings the ⌘K palette prints in `ViewModels/CommandRegistry.swift`, and
/// the shortcuts sheet's own hand-written table. They drifted, in every
/// direction at once — the sheet advertised ⌘. for Cancel, which nothing
/// bound; it listed 4 of ~16 ⌘ bindings and omitted ⌘K, a headline feature;
/// it printed two rows under one `ForEach` id so one documented behaviour
/// never rendered at all; and it taught ⇧⌘V and `v` as the same action when
/// they did two different things.
///
/// So the chord, the wording and the context live here once. The menu binds
/// `keyboardShortcut`, the palette prints `display`, and `ShortcutsSheet`
/// renders `Shortcut.sheetRows(in:)` — and `ShortcutCatalogTests` reads the
/// sources back to prove nothing binds a chord this list does not declare,
/// and nothing here is advertised that no site binds. A binding that skips
/// one of the three surfaces fails the tests rather than shipping quietly.
///
/// Adding a binding is one case plus one line in `spec`; the switch is
/// exhaustive, so it cannot be half-declared.
enum Shortcut: String, CaseIterable, Identifiable {
    // Declaration order is the order the shortcuts sheet prints, section by
    // section: the bare keys a reviewer's hand is already on first, then the
    // menu chords, then the gestures.
    //
    // Bare keys the diff pane reads, suppressed while anything is being
    // typed into (`DiffContainerView.isTypingInTextControl`).
    case nextFile
    case previousFile
    case nextChange
    case previousChange
    case markViewed
    case toggleLayout
    case focusFileFilter
    case showShortcuts

    // The file filter field.
    case clearFileFilter

    // Menu bar — live wherever the window is.
    case settings
    case commandPalette
    case openPullRequest
    case closePullRequest
    case back
    case forward
    case goToDashboard
    case toggleSidePanel
    case refresh
    case submitReview
    case markViewedMenu
    case openOnHost
    case copyDeepLink
    case keyboardShortcuts

    // Dashboard.
    case searchInbox
    case searchProjects

    // A focused composer, and the sheets.
    case sendComposer
    case submitFromForm
    case keepDraft
    case cancelOpenPullRequest
    case closeShortcuts
    case closeShortcutsReturn

    // Not keys, still part of the keyboard contract a reviewer needs: the
    // pointer gestures the diff gutter answers, the floating bar that
    // mirrors the stepping keys, and the arrows SwiftUI's `List` handles
    // inside the file tree.
    case navigationBarMoves
    case dragGutter
    case shiftClickGutter
    case fileTreeArrows

    var id: String { rawValue }

    /// One switch, so a new case has to answer every question about itself.
    var spec: Spec {
        switch self {
        case .settings:
            return Spec(chord: .keys(.character(","), [.command]), context: .app, group: .app,
                        action: "Open Settings")
        case .commandPalette:
            return Spec(chord: .keys(.character("k"), [.command]), context: .app, group: .app,
                        action: "Open the command palette — every command in the app, searchable")
        case .openPullRequest:
            return Spec(chord: .keys(.character("o"), [.command]), context: .app, group: .navigation,
                        action: "Open a pull request by URL")
        case .closePullRequest:
            return Spec(chord: .keys(.character("w"), [.shift, .command]), context: .app, group: .navigation,
                        action: "Close this pull request — drafts are kept")
        case .back:
            return Spec(chord: .keys(.character("["), [.command]), context: .app, group: .navigation,
                        action: "Back to the pull request you came from")
        case .forward:
            return Spec(chord: .keys(.character("]"), [.command]), context: .app, group: .navigation,
                        action: "Forward again")
        case .goToDashboard:
            return Spec(chord: .keys(.character("0"), [.command]), context: .app, group: .navigation,
                        action: "Go to the dashboard")
        case .toggleSidePanel:
            return Spec(chord: .keys(.character("i"), [.option, .command]), context: .app, group: .layout,
                        action: "Show or hide the side panel")
        case .refresh:
            return Spec(chord: .keys(.character("r"), [.command]), context: .app, group: .review,
                        action: "Refetch this pull request from GitHub")
        case .submitReview:
            return Spec(chord: .keys(.returnKey, [.shift, .command]), context: .app, group: .submit,
                        action: "Open the Submit Review form")
        case .markViewedMenu:
            return Spec(chord: .keys(.character("v"), [.shift, .command]), context: .app, group: .review,
                        action: Self.markViewedAction, behaviour: .markViewedAndAdvance)
        case .openOnHost:
            return Spec(chord: .keys(.character("g"), [.shift, .command]), context: .app, group: .review,
                        action: "Open this pull request on GitHub")
        case .copyDeepLink:
            return Spec(chord: .keys(.character("c"), [.shift, .command]), context: .app, group: .review,
                        action: "Copy a reviewrr:// link to this pull request")
        case .keyboardShortcuts:
            return Spec(chord: .keys(.character("/"), [.command]), context: .app, group: .help,
                        action: Self.showShortcutsAction, behaviour: .showShortcuts)

        case .searchInbox:
            return Spec(chord: .keys(.character("f"), [.command]), context: .dashboard, group: .dashboard,
                        action: "Search the inbox")
        case .searchProjects:
            return Spec(chord: .keys(.character("f"), [.shift, .command]), context: .dashboard, group: .dashboard,
                        action: "Search watched projects")

        case .nextFile:
            return Spec(chord: .keys(.character("j")), context: .diffPane, group: .navigation,
                        action: "Open the next file")
        case .previousFile:
            return Spec(chord: .keys(.character("k")), context: .diffPane, group: .navigation,
                        action: "Open the previous file")
        case .nextChange:
            return Spec(chord: .keys(.character("n")), context: .diffPane, group: .navigation,
                        action: "Next change — continues into the next file")
        case .previousChange:
            return Spec(chord: .keys(.character("p")), context: .diffPane, group: .navigation,
                        action: "Previous change — continues into the previous file")
        case .markViewed:
            return Spec(chord: .keys(.character("v")), context: .diffPane, group: .review,
                        action: Self.markViewedAction, behaviour: .markViewedAndAdvance)
        case .toggleLayout:
            return Spec(chord: .keys(.character("u")), context: .diffPane, group: .layout,
                        action: "Switch between unified and split")
        case .focusFileFilter:
            return Spec(chord: .keys(.character("/")), context: .diffPane, group: .navigation,
                        action: "Filter the file tree by path")
        case .showShortcuts:
            // `?` is shift-slash on every layout the app supports; the pane
            // allows that one modifier rather than requiring none, so the
            // key the sheet advertises is the key the pane answers.
            return Spec(chord: .keys(.character("?")), context: .diffPane, group: .help,
                        action: Self.showShortcutsAction, behaviour: .showShortcuts)

        case .clearFileFilter:
            return Spec(chord: .keys(.escape), context: .fileFilter, group: .navigation,
                        action: "In the file filter: clear what you typed, then hand the keyboard back to the diff")

        case .sendComposer:
            return Spec(chord: .keys(.returnKey, [.command]), context: .composer, group: .review,
                        action: "In a comment box: add it as a draft, or send the reply")
        case .submitFromForm:
            return Spec(chord: .keys(.returnKey, [.command]), context: .submitReviewSheet, group: .submit,
                        action: "In the Submit Review form: send the review to GitHub")
        case .keepDraft:
            return Spec(chord: .keys(.escape), context: .submitReviewSheet, group: .submit,
                        action: "In the Submit Review form: close it, keeping the draft")
        case .cancelOpenPullRequest:
            return Spec(chord: .keys(.character("."), [.command]), context: .openPullRequestSheet, group: .navigation,
                        action: "In the open-by-URL sheet: close it without opening anything")
        case .closeShortcuts:
            return Spec(chord: .keys(.escape), context: .shortcutsSheet, group: .help,
                        action: Self.closeShortcutsAction, behaviour: .closeShortcuts)
        case .closeShortcutsReturn:
            return Spec(chord: .keys(.returnKey), context: .shortcutsSheet, group: .help,
                        action: Self.closeShortcutsAction, behaviour: .closeShortcuts)

        case .navigationBarMoves:
            return Spec(chord: .other("bar"), context: .diffPane, group: .navigation,
                        action: "The same moves, floating at the bottom of the diff")
        case .dragGutter:
            return Spec(chord: .other("drag"), context: .diffPane, group: .review,
                        action: "Drag down the line numbers to comment on several lines")
        case .shiftClickGutter:
            return Spec(chord: .other("⇧-click"), context: .diffPane, group: .review,
                        action: "Extend the comment range to that line")
        case .fileTreeArrows:
            // SwiftUI's `List` provides these, not us — which is why they
            // are `.other` rather than a chord anything here binds. Whether
            // ←/→ reach a disclosure triangle at all is T-075's question.
            return Spec(chord: .other("↑ ↓ ← →"), context: .diffPane, group: .navigation,
                        action: "Move / collapse / expand in the file tree")
        }
    }

    // Wording shared by two triggers of one behaviour. Held as constants
    // rather than repeated so the pair cannot be edited apart — which is
    // exactly how ⇧⌘V came to be taught as "mark viewed" while `v` was
    // taught as "mark viewed and advance".
    private static let markViewedAction =
        "Mark this file viewed and open the next unread one — on a file already viewed, un-mark it and stay"
    private static let showShortcutsAction = "Show this list"
    private static let closeShortcutsAction = "Close this list"

    // MARK: - Derived

    var chord: Chord { spec.chord }
    var context: Context { spec.context }
    var group: Group { spec.group }
    /// What it does, phrased for the shortcuts sheet — and reused verbatim
    /// in menu and tooltip copy so the app says one thing about one key.
    var action: String { spec.action }
    var behaviour: Behaviour? { spec.behaviour }
    /// "⇧⌘V", "j", "drag" — the only string any surface should print for
    /// this binding. Derived from the chord, so nothing can advertise a key
    /// combination that is not the one bound.
    var display: String { chord.display }

    /// The binding to hand SwiftUI, or `nil` for a pointer gesture and for
    /// the arrows the file tree's `List` handles itself.
    var keyboardShortcut: KeyboardShortcut? {
        guard case .keys(let key, let modifiers) = chord, let equivalent = key.keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: Modifier.eventModifiers(modifiers))
    }

    /// The bare letters the diff pane listens for, as one string — so the
    /// pane's `onKeyPress(characters:)` set and this list cannot disagree
    /// about which keys exist.
    static var diffPaneKeyCharacters: String {
        String(allCases.compactMap { shortcut -> Character? in
            guard shortcut.context == .diffPane,
                  case .keys(.character(let character), let modifiers) = shortcut.chord,
                  modifiers.isEmpty
            else { return nil }
            return character
        })
    }

    /// Everything in one section of the sheet, in declaration order.
    static func all(in group: Group) -> [Shortcut] {
        allCases.filter { $0.group == group }
    }

    /// One section as the sheet prints it: two triggers of one behaviour
    /// share a row and show both keys, the way `j / k` always did. Printed
    /// as two rows they were two identical sentences a few lines apart —
    /// which reads exactly like the duplicate the old table had, and hides
    /// the one fact worth knowing, that they are the same action.
    static func sheetRows(in group: Group) -> [SheetRow] {
        var rows: [SheetRow] = []
        var rowIndexByBehaviour: [Behaviour: Int] = [:]
        for shortcut in all(in: group) {
            if let behaviour = shortcut.behaviour, let index = rowIndexByBehaviour[behaviour] {
                rows[index].keys += " / " + shortcut.display
                continue
            }
            if let behaviour = shortcut.behaviour { rowIndexByBehaviour[behaviour] = rows.count }
            rows.append(SheetRow(id: shortcut.id, keys: shortcut.display, action: shortcut.action))
        }
        return rows
    }

    struct SheetRow: Identifiable {
        let id: String
        var keys: String
        let action: String
    }

    // MARK: - Nested types

    struct Spec {
        let chord: Chord
        let context: Context
        let group: Group
        let action: String
        var behaviour: Behaviour? = nil
    }

    /// Two bindings that must stay the same action. ⇧⌘V and `v` did not,
    /// and pressing the one the nav bar advertised twice un-marked the file
    /// the reviewer had just finished (T-049).
    enum Behaviour: String, Hashable {
        case markViewedAndAdvance
        case showShortcuts
        case closeShortcuts
    }

    /// Where a binding is live. Two bindings may share a chord only across
    /// contexts that cannot be listening at the same moment — which is the
    /// rule ⌘⏎ broke when the Review menu, a focused composer and the
    /// submit form all claimed it at once (T-030).
    enum Context: String, CaseIterable {
        /// The menu bar: live whenever the window is, including while the
        /// reviewer is typing. Nothing else may reuse an `.app` chord.
        case app
        case dashboard
        case diffPane
        case fileFilter
        case composer
        case submitReviewSheet
        case openPullRequestSheet
        case shortcutsSheet

        var isAlwaysLive: Bool { self == .app }
    }

    /// Sections of the shortcuts sheet, in the order it prints them.
    enum Group: String, CaseIterable, Identifiable {
        case navigation
        case review
        case submit
        case layout
        case dashboard
        case app
        case help

        var id: String { rawValue }

        var title: String {
            switch self {
            case .navigation: return "Navigation"
            case .review: return "Review"
            case .submit: return "Submit review"
            case .layout: return "Layout and panels"
            case .dashboard: return "Dashboard"
            case .app: return "App"
            case .help: return "Help"
            }
        }
    }

    enum Chord: Hashable {
        /// A key, with modifiers, that the app binds itself.
        case keys(Key, Set<Modifier> = [])
        /// A trigger the app documents but does not bind: a pointer
        /// gesture, or a key the system's own controls handle.
        case other(String)

        var display: String {
            switch self {
            case .other(let label):
                return label
            case .keys(let key, let modifiers):
                return Modifier.glyphs(modifiers) + key.glyph(shifted: !modifiers.isEmpty)
            }
        }

        var isBoundKey: Bool {
            if case .keys = self { return true }
            return false
        }
    }

    enum Key: Hashable {
        case character(Character)
        case returnKey
        case escape

        /// Modified chords are printed the way macOS prints them (⇧⌘V);
        /// a bare key is printed as the reviewer types it (`v`).
        func glyph(shifted: Bool) -> String {
            switch self {
            case .character(let character):
                let text = String(character)
                return shifted ? text.uppercased() : text
            case .returnKey: return "⏎"
            case .escape: return "Esc"
            }
        }

        var keyEquivalent: KeyEquivalent? {
            switch self {
            case .character(let character): return KeyEquivalent(character)
            case .returnKey: return .return
            case .escape: return .escape
            }
        }
    }

    enum Modifier: String, CaseIterable, Hashable {
        case control
        case option
        case shift
        case command

        /// Apple's order, not declaration order: ⌃⌥⇧⌘ is what a reviewer
        /// reads in every other menu on the machine.
        var glyph: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        static func glyphs(_ modifiers: Set<Modifier>) -> String {
            allCases.filter(modifiers.contains).map(\.glyph).joined()
        }

        static func eventModifiers(_ modifiers: Set<Modifier>) -> EventModifiers {
            var result: EventModifiers = []
            if modifiers.contains(.control) { result.insert(.control) }
            if modifiers.contains(.option) { result.insert(.option) }
            if modifiers.contains(.shift) { result.insert(.shift) }
            if modifiers.contains(.command) { result.insert(.command) }
            return result
        }
    }
}
