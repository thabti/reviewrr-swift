import XCTest

/// The keyboard is the product, and it had drifted apart from its own
/// documentation in four directions at once (T-048): a duplicate row id that
/// hid a documented behaviour, a chord advertised that nothing bound, a sheet
/// with no Escape, and 4 of ~16 ⌘ bindings listed with ⌘K missing. ⇧⌘V and
/// `v` were taught as one action and did two different things (T-049), and
/// ⌘⏎ was bound four times over (T-030).
///
/// These tests pin the rules that made those possible, not the current
/// contents of the list:
///
/// - nothing binds a chord the catalog does not declare, and nothing is
///   declared that no site binds — checked by reading the sources back,
///   because the binding sites live in `Views/` and `App/`, which are not
///   compiled into this bundle;
/// - no two commands claim one chord where both can hear it;
/// - two triggers of one behaviour are described with one sentence;
/// - every declared binding reaches the sheet.
final class ShortcutCatalogTests: XCTestCase {

    // MARK: - The catalog's own rules

    func testEveryBindingHasItsOwnIdentity() {
        let ids = Shortcut.allCases.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "Two rows sharing an identity is what made the sheet print one `v` and silently drop the other"
        )
    }

    /// The T-030 rule. `.app` is the menu bar, which is live even while the
    /// reviewer is typing, so nothing may reuse one of its chords; two other
    /// contexts may share a chord because they cannot be listening at the
    /// same moment (a modal sheet and a composer in the pane behind it).
    func testNoTwoCommandsClaimOneChordWhereBothCanHearIt() {
        let bound = Shortcut.allCases.filter { $0.chord.isBoundKey }
        for (index, first) in bound.enumerated() {
            for second in bound[(index + 1)...] where first.chord == second.chord {
                if first.context == second.context {
                    XCTFail(
                        "\(first.id) and \(second.id) both claim \(first.chord.display) in \(first.context.rawValue)"
                    )
                } else if first.context.isAlwaysLive || second.context.isAlwaysLive {
                    XCTFail(
                        """
                        \(first.id) (\(first.context.rawValue)) and \(second.id) (\(second.context.rawValue)) \
                        both claim \(first.chord.display), and a menu item is live even while the reviewer is \
                        typing — this is exactly how ⌘⏎ opened the Submit Review form instead of filing a comment
                        """
                    )
                }
            }
        }
    }

    /// The T-049 rule: one behaviour, one sentence. The nav bar taught ⇧⌘V
    /// as "mark viewed" while `v` was taught as "mark viewed and open the
    /// next one", and only one of them advanced.
    func testTriggersOfOneBehaviourAreTaughtAsOneAction() {
        let described = Dictionary(grouping: Shortcut.allCases.filter { $0.behaviour != nil }) { $0.behaviour! }
        XCTAssertFalse(described.isEmpty, "The pairs this rule exists for are declared with a `behaviour`")
        for (behaviour, shortcuts) in described {
            let wordings = Set(shortcuts.map(\.action))
            XCTAssertEqual(
                wordings.count, 1,
                "\(behaviour.rawValue) is offered as \(shortcuts.map(\.display).joined(separator: " and ")) "
                + "but described \(wordings.count) different ways: \(wordings.sorted())"
            )
        }
    }

    func testEveryBindingIsAdvertisedInExactlyOneSectionOfTheSheet() {
        let listed = Shortcut.Group.allCases.flatMap { Shortcut.all(in: $0) }
        XCTAssertEqual(
            listed.count, Shortcut.allCases.count,
            "The sheet renders section by section, so a binding in no section is a binding nobody can find — "
            + "which is how ⌘K, a headline feature, went undocumented"
        )
        XCTAssertEqual(Set(listed.map(\.id)).count, listed.count, "and none may be printed twice")

        let rows = Shortcut.Group.allCases.flatMap { Shortcut.sheetRows(in: $0) }
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "Two rows under one id is how a documented key stopped rendering")
        for shortcut in Shortcut.allCases {
            XCTAssertTrue(
                rows.contains { $0.keys.split(separator: " / ").contains(Substring(shortcut.display)) },
                "\(shortcut.id) is declared but its key never reaches a printed row"
            )
        }
    }

    /// Chords print themselves, so no surface can advertise a combination
    /// that is not the one bound — the sheet used to offer ⌘. for Cancel.
    func testChordsPrintThemselvesInTheSystemsOwnOrder() {
        XCTAssertEqual(
            Shortcut.Chord.keys(.character("v"), [.command, .shift]).display, "⇧⌘V",
            "⌃⌥⇧⌘ order, and a modified letter is shown the way macOS shows it"
        )
        XCTAssertEqual(Shortcut.Chord.keys(.character("i"), [.option, .command]).display, "⌥⌘I")
        XCTAssertEqual(
            Shortcut.Chord.keys(.character("v")).display, "v",
            "A bare key is printed as the reviewer types it"
        )
        XCTAssertEqual(Shortcut.Chord.keys(.returnKey, [.command]).display, "⌘⏎")
        XCTAssertEqual(Shortcut.Chord.keys(.escape).display, "Esc")
        XCTAssertEqual(Shortcut.Chord.other("drag").display, "drag")
    }

    // MARK: - Advertised means bound

    /// Every chord bound anywhere in the app must be one this list declares.
    /// A binding the catalog does not know about is a binding the sheet
    /// cannot show and the palette cannot name.
    func testNothingBindsAChordTheCatalogDoesNotDeclare() throws {
        let declared = Set(Shortcut.allCases.map(\.chord))
        for source in try SourceTree.swiftFiles() {
            for argument in SourceTree.keyboardShortcutArguments(in: source.text) {
                switch SourceTree.parse(argument) {
                case .systemDefault, .derived:
                    continue
                case .literal(let chord):
                    XCTAssertTrue(
                        declared.contains(chord),
                        "\(source.name) binds \(chord.display), which no `Shortcut` case declares. Add it there — "
                        + "the sheet, the menu and the palette are all rendered from that list."
                    )
                case .unrecognized:
                    XCTFail(
                        "\(source.name) binds `\(argument)`, which this test cannot read. Bind it from `Shortcut` "
                        + "so the sheet documents it, or teach `SourceTree.parse` the new shape."
                    )
                }
            }
        }
    }

    /// And the other direction: every ⌘-chord this list advertises has to be
    /// installed somewhere. ⌘. for Cancel was advertised for as long as the
    /// sheet was written by hand, and nothing ever bound it.
    func testEveryModifiedChordTheCatalogAdvertisesIsActuallyBound() throws {
        var boundChords: Set<Shortcut.Chord> = []
        var boundCases: Set<Shortcut> = []
        for source in try SourceTree.swiftFiles() {
            for argument in SourceTree.keyboardShortcutArguments(in: source.text) {
                switch SourceTree.parse(argument) {
                case .literal(let chord): boundChords.insert(chord)
                case .derived(let cases): boundCases.formUnion(cases)
                case .systemDefault, .unrecognized: continue
                }
            }
        }

        for shortcut in Shortcut.allCases {
            guard case .keys(_, let modifiers) = shortcut.chord, !modifiers.isEmpty else { continue }
            XCTAssertTrue(
                boundChords.contains(shortcut.chord) || boundCases.contains(shortcut),
                "The sheet advertises \(shortcut.display) for \"\(shortcut.action)\" and nothing in Sources/ "
                + "binds it. Advertising a chord no site installs is worse than not documenting it."
            )
        }
    }

    /// The bare letters are read by the diff pane rather than bound as menu
    /// chords, so they get their own check: the pane's key set comes from
    /// this list, and its handler answers every letter in it.
    func testTheDiffPaneListensForEveryBareKeyTheSheetAdvertises() throws {
        let pane = try SourceTree.text("Views/DiffView.swift")
        XCTAssertTrue(
            pane.contains("Shortcut.diffPaneKeyCharacters"),
            "The pane's `onKeyPress(characters:)` set must come from the catalog, not a string typed beside it"
        )
        for character in Shortcut.diffPaneKeyCharacters {
            XCTAssertTrue(
                pane.contains("case \"\(character)\""),
                "`\(character)` is advertised as a diff-pane key but `DiffContainerView.handle(key:)` ignores it"
            )
        }
    }

    /// Escape and Return are not app-specific chords — they arrive as
    /// `.cancelAction`, `.defaultAction` or an `onKeyPress` — so each one
    /// this list advertises names the file that has to install it. The
    /// shortcuts sheet was the only dismissible surface in the app with no
    /// Escape at all, while its own tooltip promised one.
    func testEveryUnmodifiedKeyTheCatalogAdvertisesIsInstalledWhereItSaysItIs() throws {
        let sites: [Shortcut: (file: String, token: String)] = [
            .clearFileFilter: ("Views/Workspace/FilterBarView.swift", "onKeyPress(.escape)"),
            .keepDraft: ("Views/SubmitReviewForm.swift", "keyboardShortcut(.cancelAction)"),
            .closeShortcuts: ("Views/Workspace/ShortcutsSheet.swift", "keyboardShortcut(.cancelAction)"),
            .closeShortcutsReturn: ("Views/Workspace/ShortcutsSheet.swift", "keyboardShortcut(.defaultAction)"),
        ]

        for shortcut in Shortcut.allCases {
            guard case .keys(let key, let modifiers) = shortcut.chord, modifiers.isEmpty else { continue }
            if case .character = key { continue }  // the diff pane's bare letters, checked above
            guard let site = sites[shortcut] else {
                XCTFail(
                    "\(shortcut.id) advertises \(shortcut.display) with no modifiers and no site in this test — "
                    + "name the file that installs it so the claim stays checkable"
                )
                continue
            }
            XCTAssertTrue(
                try SourceTree.text(site.file).contains(site.token),
                "\(shortcut.id) advertises \(shortcut.display), so \(site.file) must still contain \(site.token)"
            )
        }
    }

    /// The three surfaces that used to disagree now read from one list, and
    /// this is what keeps them there: a chord typed out again in the menu, or
    /// a "⌘…" typed into a palette row, is how they came apart the first time.
    func testTheMenuBarAndThePaletteTakeTheirChordsFromTheCatalog() throws {
        let menu = try SourceTree.text("App/ReviewrrApp.swift")
        let literals = SourceTree.keyboardShortcutArguments(in: menu).filter {
            if case .literal = SourceTree.parse($0) { return true }
            return false
        }
        XCTAssertTrue(
            literals.isEmpty,
            "The menu bar binds \(literals) by hand. Every chord there comes from `Shortcut` so the sheet "
            + "and the ⌘K palette cannot fall behind it."
        )
        XCTAssertFalse(
            SourceTree.keyboardShortcutArguments(in: menu).isEmpty,
            "…and this test is only worth anything while the menu is still where the bindings live"
        )

        let palette = try SourceTree.text("ViewModels/CommandRegistry.swift")
        XCTAssertFalse(
            palette.contains("shortcut: \""),
            "The palette prints `Shortcut.<case>.display`; a hand-written label is a second claim about the keyboard"
        )
    }

    // MARK: - T-029: Escape in the file filter

    /// `/` moved the keyboard into the filter and nothing moved it out:
    /// Escape did nothing at all, and every navigation key was dead until
    /// the reviewer used the mouse. Whatever else changes, Escape in that
    /// field has to *do* something, and when there is nothing left to clear
    /// the diff has to be asked to take focus back.
    @MainActor
    func testEscapeInTheFileFilterIsNeverANoOp() {
        let workspace = WorkspaceModel()
        workspace.searchText = "auth"

        XCTAssertEqual(workspace.escapeInFileFilter(typed: "auth"), .clearedText)
        XCTAssertEqual(workspace.searchText, "", "The first Escape clears the term the reviewer typed")
        XCTAssertFalse(
            workspace.diffFocusRequested,
            "…and keeps the keyboard in the field, so they can retype without reaching for the mouse"
        )

        XCTAssertEqual(workspace.escapeInFileFilter(typed: ""), .releasedFocusToDiff)
        XCTAssertTrue(
            workspace.diffFocusRequested,
            "Releasing focus is not enough: SwiftUI focus moved into the field, so the diff has to be asked "
            + "for it back or j/k stay dead"
        )
    }

    @MainActor
    func testTheDiffPaneFocusRequestIsConsumable() {
        let workspace = WorkspaceModel()
        _ = workspace.escapeInFileFilter(typed: "")
        XCTAssertTrue(workspace.diffFocusRequested)
        workspace.diffFocusRequested = false
        XCTAssertFalse(workspace.diffFocusRequested, "The pane resets the flag once it has taken focus")
    }

    // MARK: - T-049: one mark-viewed action

    /// ⇧⌘V only toggled the flag while `v` marked and advanced, so a
    /// reviewer who trusted the navigation bar's tooltip and pressed twice
    /// un-marked the file they had just finished. Both go through
    /// `markViewedAndAdvance` now, so twice marks two files.
    @MainActor
    func testMarkingViewedTwiceMarksTwoFilesRatherThanUndoingTheFirst() {
        let model = AppModel()
        let workspace = model.workspace
        workspace.hiddenCategories = []
        workspace.searchText = ""
        workspace.refresh(files: [
            makeSourceFile("src/a.swift"),
            makeSourceFile("src/b.swift"),
            makeSourceFile("src/c.swift"),
        ])
        model.selectedFile = "src/a.swift"

        model.markViewedAndAdvance(model.selectedFile ?? "")
        XCTAssertEqual(model.selectedFile, "src/b.swift", "Finishing a file and moving on is one action")

        model.markViewedAndAdvance(model.selectedFile ?? "")
        XCTAssertEqual(
            model.draft.viewedFiles, ["src/a.swift", "src/b.swift"],
            "Two presses mark two files. Pressing the advertised chord twice must never un-mark work."
        )
    }

    @MainActor
    func testUnMarkingAViewedFileStaysOnIt() {
        let model = AppModel()
        let workspace = model.workspace
        workspace.hiddenCategories = []
        workspace.searchText = ""
        workspace.refresh(files: [makeSourceFile("src/a.swift"), makeSourceFile("src/b.swift")])
        model.selectedFile = "src/a.swift"
        model.markViewedAndAdvance("src/a.swift")
        XCTAssertEqual(model.selectedFile, "src/b.swift")

        model.markViewedAndAdvance("src/b.swift")
        let selectionAfterMarking = model.selectedFile

        model.markViewedAndAdvance("src/b.swift")
        XCTAssertFalse(model.draft.viewedFiles.contains("src/b.swift"), "The gesture is its own undo")
        XCTAssertEqual(
            model.selectedFile, selectionAfterMarking,
            "Un-marking is a second look at that file, so it must not move the reviewer anywhere"
        )
    }

    private func makeSourceFile(_ path: String) -> PRFile {
        PRFile(
            filename: path, previousFilename: nil, status: .modified,
            additions: 1, deletions: 1, changes: 2, patch: "@@ -1,1 +1,1 @@\n-a\n+b"
        )
    }
}

// MARK: - Reading the binding sites back

/// `Views/` and `App/` are deliberately not compiled into this bundle, so
/// the only way to check a claim about what the app binds is to read the
/// source. Located from `#filePath` rather than a working directory, which
/// the test runner does not promise.
private enum SourceTree {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ReviewrrTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Sources/Reviewrr")

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func swiftFiles() throws -> [(name: String, text: String)] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Sources/Reviewrr is not readable from \(directory.path)")
        }
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        guard !files.isEmpty else { throw XCTSkip("No sources found under \(directory.path)") }
        return files
    }

    /// The argument text of every `.keyboardShortcut(…)` call. Deliberately
    /// simple-minded: an argument list it cannot read fails the test rather
    /// than being skipped, because a binding this test cannot see is exactly
    /// the binding that drifts.
    static func keyboardShortcutArguments(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\.keyboardShortcut\(([^)\n]*)\)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    enum Parsed {
        /// `.defaultAction` / `.cancelAction`: the system's own OK and
        /// Cancel, not a chord this app names or advertises.
        case systemDefault
        case literal(Shortcut.Chord)
        case derived(Set<Shortcut>)
        case unrecognized
    }

    static func parse(_ argument: String) -> Parsed {
        if argument.contains(".defaultAction") || argument.contains(".cancelAction") { return .systemDefault }

        let cases = Set(matches(#"Shortcut\.([a-zA-Z]+)"#, in: argument).compactMap(Shortcut.init(rawValue:)))
        if !cases.isEmpty { return .derived(cases) }

        let key: Shortcut.Key?
        if let quoted = matches(#""(.)""#, in: argument).first, let character = quoted.first {
            key = .character(character)
        } else if argument.contains(".return") {
            key = .returnKey
        } else if argument.contains(".escape") {
            key = .escape
        } else {
            key = nil
        }
        guard let key else { return .unrecognized }

        var modifiers: Set<Shortcut.Modifier> = []
        for modifier in Shortcut.Modifier.allCases where argument.contains("modifiers:") {
            if argument.contains(".\(modifier.rawValue)") { modifiers.insert(modifier) }
        }
        return .literal(.keys(key, modifiers))
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
