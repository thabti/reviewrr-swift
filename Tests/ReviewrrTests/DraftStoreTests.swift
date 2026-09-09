import XCTest

final class DraftStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ draft: ReviewDraft, name: String) throws {
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func testLegacyDraftRemainsDiscoverableWithRepositoryUnderscores() throws {
        let data = Data(#"{"summary":"Review this edge case","event":"REQUEST_CHANGES","comments":[],"viewedFiles":["a.swift"]}"#.utf8)
        try data.write(to: directory.appendingPathComponent("acme_repo_with_underscores_42.json"))
        let result = DraftStore.savedReviews(in: directory)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.reference.key, "acme/repo_with_underscores#42")
        XCTAssertEqual(result.first?.draft.summary, "Review this edge case")
        XCTAssertEqual(result.first?.draft.event, .requestChanges)
        XCTAssertEqual(result.first?.draft.viewedFiles, ["a.swift"])
    }

    func testOpenedReviewsAreListedNewestFirstWithoutComments() throws {
        var first = ReviewDraft()
        first.referenceKey = "acme/one#1"
        first.savedAt = Date(timeIntervalSince1970: 10)
        var second = ReviewDraft()
        second.referenceKey = "acme/two#2"
        second.savedAt = Date(timeIntervalSince1970: 20)
        try write(first, name: "first.json")
        try write(second, name: "second.json")
        XCTAssertEqual(DraftStore.savedReviews(in: directory).map(\.id), ["acme/two#2", "acme/one#1"])
    }

    func testSubmittedEmptyLegacyAndCorruptFilesDoNotBecomeActiveDrafts() throws {
        var submitted = ReviewDraft()
        submitted.referenceKey = "acme/repo#1"
        submitted.viewedFiles = ["file.swift"]
        submitted.isSubmitted = true
        try write(submitted, name: "submitted.json")
        try write(ReviewDraft(), name: "acme_repo_2.json")
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent("acme_repo_3.json"))
        XCTAssertTrue(DraftStore.savedReviews(in: directory).isEmpty)
    }

    func testDiscardedDraftIsExcludedEvenWithReferenceMetadata() throws {
        var cleared = ReviewDraft()
        cleared.referenceKey = "acme/repo#1"
        cleared.isDiscarded = true
        try write(cleared, name: "acme_repo_1.json")
        XCTAssertTrue(DraftStore.savedReviews(in: directory).isEmpty)
        let decoded = try JSONDecoder().decode(ReviewDraft.self, from: Data(contentsOf: directory.appendingPathComponent("acme_repo_1.json")))
        XCTAssertEqual(decoded.isDiscarded, true)
        XCTAssertTrue(decoded.comments.isEmpty)
        XCTAssertTrue(decoded.summary.isEmpty)
        XCTAssertTrue(decoded.viewedFiles.isEmpty)
    }

    func testPendingComposerPreservesAnchorAndTextAcrossDiskRoundTrip() throws {
        var draft = ReviewDraft()
        draft.referenceKey = "acme/repo#1"
        let comment = DraftComment(path: "src/test.swift", line: 18, side: .right, body: "Unfinished thought", headSha: "old-head")
        draft.pendingComments = ["anchor": comment]
        try write(draft, name: "acme_repo_1.json")
        let restored = try XCTUnwrap(DraftStore.savedReviews(in: directory).first)
        XCTAssertEqual(restored.draft.pendingComments?["anchor"], comment)
        XCTAssertTrue(restored.draft.comments.isEmpty)
    }
}
