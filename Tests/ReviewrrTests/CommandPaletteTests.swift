import XCTest

final class CommandMatcherTests: XCTestCase {
    private func command(
        _ id: String, _ title: String, group: PaletteCommand.Group = .pullRequest,
        subtitle: String? = nil, keywords: [String] = [], enabled: Bool = true
    ) -> PaletteCommand {
        PaletteCommand(
            id: id, title: title, subtitle: subtitle, symbol: "circle",
            group: group, keywords: keywords, isEnabled: enabled
        ) {}
    }

    func testInitialsMatchAcrossWords() {
        // The whole point of a palette: three keystrokes should reach a
        // command whose exact wording you do not remember.
        let commands = [command("a", "Submit Review"), command("b", "Refresh Pull Request")]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "sbr").map(\.id), ["a"])
        XCTAssertEqual(CommandMatcher.rank(commands, query: "rpr").map(\.id), ["b"])
    }

    func testPrefixOutranksLaterMatch() {
        let commands = [
            command("later", "Mark All Files Viewed"),
            command("prefix", "Files"),
        ]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "file").first?.id, "prefix")
    }

    func testTitleMatchOutranksSubtitleMatch() {
        let commands = [
            command("subtitle", "Open on GitHub", subtitle: "payments-service"),
            command("title", "Payments"),
        ]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "payments").first?.id, "title")
    }

    func testKeywordMatchesWithoutAppearingInTitle() {
        let commands = [command("theme", "Appearance: Dark", keywords: ["theme", "dark mode"])]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "theme").map(\.id), ["theme"])
    }

    func testNonMatchingQueryReturnsNothing() {
        XCTAssertTrue(CommandMatcher.rank([command("a", "Submit Review")], query: "zzz").isEmpty)
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let commands = [command("a", "Résumé Analysis")]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "RESUME").map(\.id), ["a"])
    }

    func testDisabledCommandsStillMatchButSinkToTheBottom() {
        // Hiding a disabled command hides the fact that it exists; showing it
        // greyed teaches the reviewer what the app can do.
        let commands = [command("off", "Submit Review", enabled: false), command("on", "Submit Rebase", enabled: true)]
        let ranked = CommandMatcher.rank(commands, query: "submit")
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.last?.id, "off")
    }

    func testEmptyQueryFloatsRecentCommandsFirst() {
        let commands = [
            command("first", "Alpha", group: .go),
            command("second", "Beta", group: .go),
            command("third", "Gamma", group: .view),
        ]
        let ranked = CommandMatcher.rank(commands, query: "", recentIDs: ["third"])
        XCTAssertEqual(ranked.first?.id, "third")
    }

    func testEmptyQueryOtherwiseOrdersByGroup() {
        let commands = [
            command("view", "Split", group: .view),
            command("go", "Dashboard", group: .go),
        ]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "").map(\.id), ["go", "view"])
    }

    func testShorterCandidateWinsEqualMatches() {
        let commands = [
            command("long", "Open on GitHub in the Default Browser"),
            command("short", "Open on GitHub"),
        ]
        XCTAssertEqual(CommandMatcher.rank(commands, query: "opengithub").first?.id, "short")
    }
}

@MainActor
final class CommandPaletteModelTests: XCTestCase {
    private func makeModel(_ commands: [PaletteCommand]) -> CommandPaletteModel {
        let model = CommandPaletteModel()
        model.provider = { commands }
        model.open()
        return model
    }

    private func command(_ id: String, _ title: String, enabled: Bool = true, run: @escaping @MainActor () -> Void = {}) -> PaletteCommand {
        PaletteCommand(id: id, title: title, symbol: "circle", group: .pullRequest, isEnabled: enabled, run: run)
    }

    func testOpenLoadsCommandsAndResetsQuery() {
        let model = makeModel([command("a", "Alpha"), command("b", "Beta")])
        model.query = "alpha"
        XCTAssertEqual(model.results.map(\.id), ["a"])
        model.open()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.results.count, 2)
    }

    func testSelectionWrapsInBothDirections() {
        let model = makeModel([command("a", "Alpha"), command("b", "Beta")])
        XCTAssertEqual(model.selectionIndex, 0)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectionIndex, 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectionIndex, 0)
    }

    func testTypingResetsSelectionToTheTop() {
        let model = makeModel([command("a", "Alpha"), command("b", "Beta")])
        model.moveSelection(by: 1)
        model.query = "b"
        XCTAssertEqual(model.selectionIndex, 0)
    }

    func testRunSelectedInvokesTheCommand() {
        var ran = false
        let model = makeModel([command("a", "Alpha") { ran = true }])
        XCTAssertTrue(model.runSelected())
        XCTAssertTrue(ran)
    }

    func testDisabledCommandDoesNotRun() {
        var ran = false
        let model = makeModel([command("a", "Alpha", enabled: false) { ran = true }])
        XCTAssertFalse(model.runSelected())
        XCTAssertFalse(ran)
    }

    func testGroupedResultsPreserveRankOrder() {
        let go = PaletteCommand(id: "go", title: "Dashboard", symbol: "c", group: .go) {}
        let view = PaletteCommand(id: "view", title: "Split", symbol: "c", group: .view) {}
        let model = makeModel([view, go])
        XCTAssertEqual(model.groupedResults.map(\.group), [.go, .view])
    }
}
