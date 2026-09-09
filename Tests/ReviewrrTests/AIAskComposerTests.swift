import XCTest

@MainActor
final class AIAskComposerTests: XCTestCase {
    /// The composer takes whole `PRFile`s so the picker can show what
    /// changed and by how much; these tests only care about the paths.
    private func files(_ paths: String...) -> [PRFile] {
        paths.map {
            PRFile(filename: $0, previousFilename: nil, status: .modified,
                   additions: 1, deletions: 0, changes: 1, patch: "@@ -1 +1 @@\n+x")
        }
    }

    func testMentionAtCursorPreservesFollowingQuestionAndUnicode() {
        let model = AIAskComposerModel()
        model.files = files("Sources/Cache.swift", "Tests/Cache.swift")
        let prefix = "👋 explain @Cache"
        model.update(text: prefix + " behavior", selection: NSRange(location: prefix.utf16.count, length: 0))
        XCTAssertEqual(model.matches.count, 2)
        model.choose("Tests/Cache.swift")
        XCTAssertEqual(model.text, "👋 explain  behavior")
        XCTAssertEqual(model.taggedPaths, ["Tests/Cache.swift"])
        XCTAssertEqual(model.scope, .files(["Tests/Cache.swift"]))
    }

    func testEmailAndEscapedPickerDoNotTriggerMentions() {
        let model = AIAskComposerModel()
        model.update(text: "user@example.com", selection: NSRange(location: 16, length: 0))
        XCTAssertNil(model.mentionRange)
        model.update(text: "@", selection: NSRange(location: 1, length: 0))
        XCTAssertNotNil(model.mentionRange)
        XCTAssertTrue(model.handle("cancelOperation:"))
        XCTAssertNil(model.mentionRange)
    }

    func testKeyboardSelectionAndDeduplication() {
        let model = AIAskComposerModel()
        model.files = files("a/File.swift", "b/File.swift")
        model.update(text: "@File", selection: NSRange(location: 5, length: 0))
        XCTAssertTrue(model.handle("moveDown:"))
        XCTAssertTrue(model.handle("insertTab:"))
        XCTAssertEqual(model.taggedPaths, ["b/File.swift"])
        model.showPicker()
        XCTAssertEqual(model.matches, ["a/File.swift"])
        XCTAssertTrue(model.handle("insertNewline:"))
        XCTAssertEqual(model.taggedPaths.count, 2)
    }

    func testPickerButtonReplacesSelectedTextAndSupportsSpaceInFilename() {
        let model = AIAskComposerModel()
        model.files = files("Sources/My File.swift")
        model.update(text: "Explain this please", selection: NSRange(location: 8, length: 4))
        model.showPicker()
        XCTAssertEqual(model.text, "Explain @ please")
        model.choose("Sources/My File.swift")
        XCTAssertEqual(model.text, "Explain  please")
        XCTAssertEqual(model.taggedPaths, ["Sources/My File.swift"])
    }

    // MARK: - Ranking what `@` offers

    /// What a reviewer means by typing a few letters, in order: the file
    /// called that, then files starting with it, then files containing it,
    /// then anywhere in the path. The old rule had only the second of these
    /// and let everything else tie on alphabetical order.
    func testTheFileYouNamedComesFirst() {
        let candidates = [
            "src/components/ButtonGroup.tsx",
            "src/legacy/button/index.ts",
            "src/Button.tsx",
            "src/components/IconButton.tsx",
        ]
        XCTAssertEqual(
            AIAskComposerModel.rank(candidates, query: "button"),
            [
                "src/Button.tsx",                     // the file is called that
                "src/components/ButtonGroup.tsx",     // name starts with it
                "src/components/IconButton.tsx",      // name contains it
                "src/legacy/button/index.ts",         // only the path contains it
            ]
        )
    }

    func testMatchingIsCaseInsensitiveAndReachesTheDirectory() {
        let candidates = ["Sources/Reviewrr/Services/Keychain.swift", "Tests/Other.swift"]
        XCTAssertEqual(AIAskComposerModel.rank(candidates, query: "KEYCHAIN"), [candidates[0]])
        XCTAssertEqual(AIAskComposerModel.rank(candidates, query: "services"), [candidates[0]])
        XCTAssertTrue(AIAskComposerModel.rank(candidates, query: "nothing-here").isEmpty)
    }

    /// No query is the "show me everything" case the chip and a bare `@`
    /// both produce, and it must not drop anything.
    func testAnEmptyQueryListsEveryCandidateInOrder() {
        let candidates = ["b/Two.swift", "a/One.swift"]
        XCTAssertEqual(AIAskComposerModel.rank(candidates, query: ""), ["a/One.swift", "b/Two.swift"])
    }

    // MARK: - Tags that outlived their file

    /// A push can take a tagged file away. Send is blocked while that is
    /// true, so the composer has to be able to say which ones and drop them.
    func testTagsForFilesThatLeftThePullRequestAreNamedAndDroppable() {
        let model = AIAskComposerModel()
        model.files = files("kept.swift", "also-kept.swift")
        model.taggedPaths = ["kept.swift", "gone.swift"]
        XCTAssertEqual(model.staleTaggedPaths, ["gone.swift"])
        model.dropStaleTags()
        XCTAssertEqual(model.taggedPaths, ["kept.swift"])
        XCTAssertTrue(model.staleTaggedPaths.isEmpty)
        model.untagAll()
        XCTAssertEqual(model.scope, .wholePR)
    }

    func testMessageTagsRoundTripAndLegacyMessagesDecode() throws {
        let message = ChatMessage(role: .user, content: "Compare these", taggedFiles: ["a/File.swift", "b/File.swift"])
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)), message)
        let legacy = Data(#"{"role":"user","content":"Hello"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: legacy).taggedFiles)
    }

    func testTaggedContextExcludesOtherDiffsAndRejectsMissingFiles() throws {
        let engine = AIEngine(context: .stub())
        let files = ["a.swift", "b.swift", "c.swift"].enumerated().map { index, path in
            PRFile(filename: path, previousFilename: nil, status: .modified, additions: 1, deletions: 0, changes: 1,
                   patch: "@@ -1 +1 @@\n+UNIQUE_TAGGED_PATCH_\(index)")
        }
        let situation = AIReviewSituation(reference: DemoFixture.reference, host: "github.com", pullRequest: DemoFixture.pullRequest,
                                         files: files, issueComments: [], reviewComments: [], draft: ReviewDraft(), priorRun: nil)
        let bounded = try engine.boundedAskContext(situation: situation, scope: .files(["a.swift", "c.swift"]), providerID: "codex")
        XCTAssertTrue(bounded.text.contains("UNIQUE_TAGGED_PATCH_0"))
        XCTAssertTrue(bounded.text.contains("UNIQUE_TAGGED_PATCH_2"))
        XCTAssertFalse(bounded.text.contains("UNIQUE_TAGGED_PATCH_1"))
        XCTAssertThrowsError(try engine.boundedAskContext(situation: situation, scope: .files(["missing.swift"]), providerID: "codex"))
    }
}
