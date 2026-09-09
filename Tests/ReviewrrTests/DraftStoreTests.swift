import XCTest

final class DraftStoreTests: XCTestCase {
    private var directory: URL!
    /// Files this test created in the app's real Application Support store,
    /// removed in `tearDown`. The store's directory layout is private, so the
    /// tests that have to exercise it for real (quarantine, migration) work
    /// against the same place the app does.
    private var createdInRealStore: [URL] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        for url in createdInRealStore {
            try? FileManager.default.removeItem(at: url)
        }
        createdInRealStore = []
    }

    private func write(_ draft: ReviewDraft, name: String) throws {
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - Real-store helpers

    /// Rebuilt from the outside on purpose: where a draft lands is a
    /// compatibility contract, so a change to the layout that arrives without
    /// a migration should fail here rather than orphan a reviewer's drafts.
    private func realDraftsDirectory(host: ForgeHost = .dotCom) -> URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reviewrr/drafts", isDirectory: true)
        if !host.isDotCom { dir = dir.appendingPathComponent(host.identityKey, isDirectory: true) }
        return dir
    }

    /// A reference nobody's real store can already contain, so a test never
    /// reads or clobbers the drafts of whoever is running it.
    private func scratchReference(owner: String = "reviewrr-tests", number: Int = 1) -> PRReference {
        PRReference(owner: owner, repo: "scratch-\(UUID().uuidString.prefix(8))", number: number)
    }

    private func track(_ url: URL) -> URL {
        createdInRealStore.append(url)
        return url
    }

    /// Every file the store may have produced for one reference, so cleanup
    /// catches the quarantine copies too.
    private func trackAll(matching name: String, host: ForgeHost = .dotCom) {
        let base = (name as NSString).deletingPathExtension
        let directory = realDraftsDirectory(host: host)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(base) {
            createdInRealStore.append(url)
        }
    }

    // MARK: - Listing (T-051: legacy names stay readable)

    /// T-011: the payload deliberately carries *only* `summary`. It used to
    /// spell out every key `ReviewDraft` had at the time, which quietly baked
    /// in the assumption the synthesized decoder made — that a stored draft
    /// always contains every field this build knows about. That assumption is
    /// the bug: one field added in a later release, and every reviewer's
    /// staged review stops decoding. A file from *any* version has to load,
    /// so the fixture is now the oldest shape imaginable.
    func testLegacyDraftRemainsDiscoverableWithRepositoryUnderscores() throws {
        let data = Data(#"{"summary":"Review this edge case"}"#.utf8)
        try data.write(to: directory.appendingPathComponent("acme_repo_with_underscores_42.json"))
        let result = DraftStore.savedReviews(in: directory)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.reference.key, "acme/repo_with_underscores#42")
        XCTAssertEqual(result.first?.draft.summary, "Review this edge case")
        XCTAssertEqual(result.first?.draft.event, .comment, "The default survives the key being absent")
        XCTAssertEqual(result.first?.draft.viewedFiles, [], "As does this one")
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

    /// A nested GitLab group path is three segments deep, which
    /// `PRReference.parse` rejects. Listing must not: the draft saves now, and
    /// dropping it off the shelf would be the same loss by another route.
    func testNestedGitLabDraftIsListed() throws {
        var draft = ReviewDraft()
        draft.referenceKey = "platform/payments/api#318"
        draft.summary = "Eight comments"
        try write(draft, name: PRStoreFileName.json(for: PRReference(owner: "platform/payments", repo: "api", number: 318)))
        let listed = try XCTUnwrap(DraftStore.savedReviews(in: directory).first)
        XCTAssertEqual(listed.reference.owner, "platform/payments")
        XCTAssertEqual(listed.reference.repo, "api")
        XCTAssertEqual(listed.reference.number, 318)
    }

    // MARK: - T-011: a missing key must never cost a review

    func testDraftDecodesWithNoKeysAtAll() throws {
        let draft = try JSONDecoder().decode(ReviewDraft.self, from: Data("{}".utf8))
        XCTAssertEqual(draft.summary, "")
        XCTAssertEqual(draft.event, .comment)
        XCTAssertTrue(draft.comments.isEmpty)
        XCTAssertTrue(draft.viewedFiles.isEmpty)
        XCTAssertNil(draft.referenceKey)
        XCTAssertEqual(draft.schemaVersion, 1, "A file written before versioning is version 1")
    }

    func testDraftDecodeIgnoresAKeyThisBuildDoesNotKnow() throws {
        let payload = Data(#"{"summary":"kept","somethingFromTheFuture":{"nested":[1,2]}}"#.utf8)
        let draft = try JSONDecoder().decode(ReviewDraft.self, from: payload)
        XCTAssertEqual(draft.summary, "kept")
    }

    func testDraftCommentDecodesWhenOnlyItsAnchorIsPresent() throws {
        let comment = try JSONDecoder().decode(DraftComment.self, from: Data(#"{"path":"a.swift","line":12}"#.utf8))
        XCTAssertEqual(comment.path, "a.swift")
        XCTAssertEqual(comment.line, 12)
        XCTAssertEqual(comment.side, .right)
        XCTAssertEqual(comment.body, "")
        XCTAssertEqual(comment.headSha, "")
        XCTAssertNil(comment.startLine)
    }

    /// One broken comment used to cost every comment in the review, because
    /// the array was decoded as a whole.
    func testOneUnreadableCommentDoesNotTakeTheOthersWithIt() throws {
        let payload = Data(#"""
        {"summary":"s","comments":[
          {"path":"a.swift","line":1,"side":"RIGHT","body":"first","headSha":"h"},
          {"line":9,"body":"anchorless"},
          {"path":"b.swift","line":2,"side":"RIGHT","body":"third","headSha":"h"}
        ]}
        """#.utf8)
        let draft = try JSONDecoder().decode(ReviewDraft.self, from: payload)
        XCTAssertEqual(draft.comments.map(\.body), ["first", "third"])
        XCTAssertEqual(draft.summary, "s")
    }

    func testOneUnreadablePendingCommentDoesNotTakeTheOthersWithIt() throws {
        let payload = Data(#"""
        {"pendingComments":{
          "good":{"path":"a.swift","line":1,"side":"RIGHT","body":"half-typed","headSha":"h"},
          "bad":{"body":"no anchor"}
        }}
        """#.utf8)
        let draft = try JSONDecoder().decode(ReviewDraft.self, from: payload)
        XCTAssertEqual(draft.pendingComments?.count, 1)
        XCTAssertEqual(draft.pendingComments?["good"]?.body, "half-typed")
    }

    func testDraftSurvivesAFullDiskRoundTrip() throws {
        var draft = ReviewDraft()
        draft.referenceKey = "platform/payments/api#318"
        draft.title = "Charge idempotency"
        draft.summary = "Two blockers"
        draft.event = .requestChanges
        draft.viewedFiles = ["a.swift", "b.swift"]
        draft.comments = [DraftComment(path: "a.swift", line: 4, side: .right, body: "here", headSha: "h", startLine: 2, startSide: .right)]
        draft.pendingComments = ["k": DraftComment(path: "b.swift", line: 7, side: .left, body: "typing", headSha: "h")]
        draft.savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let round = try JSONDecoder().decode(ReviewDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(round, draft)
    }

    /// The whole map used to be lost when one entry was unreadable, so every
    /// PR went back to "New" and every ignored PR started shouting again.
    func testOneBrokenLocalStatusEntryDoesNotCostTheWholeMap() throws {
        let payload = Data(#"""
        {"acme/a#1":{"status":"reviewed","reviewedAtHeadSha":"abc"},
         "acme/b#2":{},
         "acme/c#3":42}
        """#.utf8)
        let map = try JSONDecoder().decode([String: LocalPRStatus].self, from: payload)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map["acme/a#1"]?.status, .reviewed)
        XCTAssertEqual(map["acme/a#1"]?.reviewedAtHeadSha, "abc")
        // Spelled out rather than `.none`, which Swift reads as `Optional.none`.
        XCTAssertEqual(map["acme/b#2"]?.status, LocalReviewStatus.none, "A missing key is a default, not a failure")
        XCTAssertEqual(map["acme/c#3"]?.status, LocalReviewStatus.none, "And neither is an entry that is not an object")
    }

    func testLocalStatusRoundTripsThroughItsOwnCodec() throws {
        var status = LocalPRStatus()
        status.setStatus(.reviewed, headSha: "head", updatedAt: Date(timeIntervalSince1970: 99))
        let round = try JSONDecoder().decode(LocalPRStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(round, status)
    }

    // MARK: - T-012 / T-050 / T-051: the file name

    func testFileNameNeverContainsAPathSeparator() {
        let references = [
            PRReference(owner: "platform/payments", repo: "api", number: 318),
            PRReference(owner: "a/b/c/d/e", repo: "deep", number: 1),
            PRReference(owner: "acme", repo: "web-app", number: 42),
            PRReference(owner: "..", repo: "..", number: 1),
        ]
        for reference in references {
            let name = PRStoreFileName.json(for: reference)
            XCTAssertFalse(name.contains("/"), "\(name) would be written into a directory nobody created")
            XCTAssertFalse(name.contains(":"))
            XCTAssertEqual(
                URL(fileURLWithPath: "/tmp").appendingPathComponent(name).lastPathComponent, name,
                "The name has to survive appendingPathComponent as one component"
            )
        }
    }

    func testReferencesDifferingOnlyByGroupDepthDoNotCollide() {
        let nested = PRStoreFileName.json(for: PRReference(owner: "platform/payments", repo: "api", number: 318))
        let shallow = PRStoreFileName.json(for: PRReference(owner: "payments", repo: "api", number: 318))
        let deeper = PRStoreFileName.json(for: PRReference(owner: "acme/platform/payments", repo: "api", number: 318))
        XCTAssertNotEqual(nested, shallow)
        XCTAssertNotEqual(nested, deeper)
    }

    /// `a_b/c` and `a/b_c` both flattened to `a_b_c_1.json`, so two projects
    /// shared one draft file and whichever was saved last won.
    func testUnderscoresInPathsCannotCollide() {
        XCTAssertNotEqual(
            PRStoreFileName.json(for: PRReference(owner: "a_b", repo: "c", number: 1)),
            PRStoreFileName.json(for: PRReference(owner: "a", repo: "b_c", number: 1))
        )
    }

    func testHostsDifferingOnlyByCaseDoNotCollide() {
        let lower = ForgeHost(
            forge: .github, displayName: "GHES", apiBaseURL: URL(string: "https://git.corp.example/api/v3")!,
            webBaseURL: URL(string: "https://git.corp.example")!, graphQLURL: URL(string: "https://git.corp.example/api/graphql")!
        )
        let upper = ForgeHost(
            forge: .github, displayName: "GHES", apiBaseURL: URL(string: "https://Git.Corp.Example/api/v3")!,
            webBaseURL: URL(string: "https://Git.Corp.Example")!, graphQLURL: URL(string: "https://Git.Corp.Example/api/graphql")!
        )
        let reference = PRReference(owner: "acme", repo: "web", number: 1)
        XCTAssertNotEqual(PRStoreFileName.json(for: reference, host: lower), PRStoreFileName.json(for: reference, host: upper))
        XCTAssertNotEqual(lower.identityKey, upper.identityKey, "The directory must not collide either")
    }

    /// The name has to be the same next launch: the inbox cache once named
    /// its file from `hashValue`, which Swift seeds per process, and the cache
    /// never hit again.
    func testFileNameIsStableAndHostSpecific() {
        let reference = PRReference(owner: "platform/payments", repo: "api", number: 318)
        XCTAssertEqual(PRStoreFileName.json(for: reference), PRStoreFileName.json(for: reference))
        let gitlab = ForgeHost(
            forge: .gitlab, displayName: "GitLab", apiBaseURL: URL(string: "https://gitlab.example/api/v4")!,
            webBaseURL: URL(string: "https://gitlab.example")!, graphQLURL: URL(string: "https://gitlab.example/api/graphql")!
        )
        XCTAssertNotEqual(PRStoreFileName.json(for: reference), PRStoreFileName.json(for: reference, host: gitlab))
    }

    func testStoredKeyParsingAcceptsAnyGroupDepth() {
        XCTAssertEqual(PRStoreFileName.reference(key: "acme/web#42"), PRReference(owner: "acme", repo: "web", number: 42))
        XCTAssertEqual(
            PRStoreFileName.reference(key: "platform/payments/api#318"),
            PRReference(owner: "platform/payments", repo: "api", number: 318)
        )
        XCTAssertNil(PRStoreFileName.reference(key: "acme/web"))
        XCTAssertNil(PRStoreFileName.reference(key: "acme#42"))
        XCTAssertNil(PRStoreFileName.reference(key: "acme/web#not-a-number"))
    }

    func testLegacyNameParsingKeepsUnderscoredRepositories() {
        XCTAssertEqual(
            PRStoreFileName.legacyReference(fileName: "acme_repo_with_underscores_42.json"),
            PRReference(owner: "acme", repo: "repo_with_underscores", number: 42)
        )
        XCTAssertNil(PRStoreFileName.legacyReference(fileName: "0123456789abcdef0123456789abcdef.json"))
        XCTAssertNil(PRStoreFileName.legacyReference(fileName: "filenames-hashed.marker"))
    }

    /// The T-012 symptom, end to end: a merge request one subgroup deep could
    /// not be saved at all — the name held a slash and the write failed with
    /// ENOENT, reported as a disk-space problem.
    func testNestedGitLabDraftSavesAndReadsBack() throws {
        let reference = PRReference(owner: "platform/payments", repo: "scratch-\(UUID().uuidString.prefix(8))", number: 318)
        var draft = ReviewDraft()
        draft.referenceKey = reference.key
        draft.summary = "Eight comments"
        _ = track(realDraftsDirectory().appendingPathComponent(PRStoreFileName.json(for: reference)))
        XCTAssertNoThrow(try DraftStore.saveChecked(draft, for: reference, host: .dotCom))
        guard case .decoded(let restored) = DraftStore.read(for: reference) else {
            return XCTFail("A draft that was just written must read back")
        }
        XCTAssertEqual(restored.summary, "Eight comments")
    }

    // MARK: - T-010: unreadable is not the same as empty

    func testAbsentDraftIsReportedAsAbsent() {
        XCTAssertEqual(DraftStore.read(for: scratchReference()), .absent)
    }

    func testUnreadableDraftIsQuarantinedRatherThanLeftToBeOverwritten() throws {
        let reference = scratchReference()
        let name = PRStoreFileName.json(for: reference)
        let url = track(realDraftsDirectory().appendingPathComponent(name))
        let original = Data(#"{"summary":"eight comments","comments":[{"pa"#.utf8)
        try FileManager.default.createDirectory(at: realDraftsDirectory(), withIntermediateDirectories: true)
        try original.write(to: url, options: .atomic)

        guard case .unreadable(let quarantinedAt, let reason) = DraftStore.read(for: reference) else {
            return XCTFail("A truncated draft file is unreadable, not empty")
        }
        trackAll(matching: name)
        let kept = try XCTUnwrap(quarantinedAt)
        XCTAssertFalse(reason.isEmpty, "The banner needs something to say")
        XCTAssertTrue(kept.lastPathComponent.contains(".corrupt-"), kept.lastPathComponent)
        XCTAssertFalse(kept.lastPathComponent.hasSuffix(".json"), "A quarantined file must not be listed as a draft")
        XCTAssertEqual(try Data(contentsOf: kept), original, "The reviewer's own bytes are still on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "And the live path is free for the next save")
    }

    func testTheSaveAfterAnUnreadableLoadDoesNotDestroyTheOldBytes() throws {
        let reference = scratchReference()
        let name = PRStoreFileName.json(for: reference)
        let url = track(realDraftsDirectory().appendingPathComponent(name))
        let original = Data("not json at all".utf8)
        try FileManager.default.createDirectory(at: realDraftsDirectory(), withIntermediateDirectories: true)
        try original.write(to: url, options: .atomic)

        guard case .unreadable(let quarantinedAt, _) = DraftStore.read(for: reference) else {
            return XCTFail("Expected an unreadable file")
        }
        trackAll(matching: name)
        // What `AppModel` does next: the reviewer starts typing and a save
        // lands. It must not land on top of what could not be read.
        var fresh = ReviewDraft()
        fresh.referenceKey = reference.key
        fresh.summary = "started again"
        try DraftStore.saveChecked(fresh, for: reference, host: .dotCom)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantinedAt)), original)
        guard case .decoded(let reread) = DraftStore.read(for: reference) else {
            return XCTFail("The new draft should read back")
        }
        XCTAssertEqual(reread.summary, "started again")
    }

    /// A listing pass must not rename anything: renaming a reviewer's files
    /// during a routine dashboard refresh is not something they asked for, and
    /// `read` does it when they actually open the pull request.
    func testListingDoesNotQuarantineWhatItCannotDecode() throws {
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent("acme_repo_3.json"))
        XCTAssertTrue(DraftStore.savedReviews(in: directory).isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), ["acme_repo_3.json"]
        )
    }

    // MARK: - Migration: no existing draft may be orphaned

    /// A draft written by the *current* version carries its identity only in
    /// its filename. Renaming it without recovering that identity would leave
    /// it on disk and invisible, which is worse than the bug being fixed.
    func testDraftWrittenUnderTheOldNameIsFoundAfterMigration() throws {
        let reference = scratchReference(owner: "reviewrr-tests-\(UUID().uuidString.prefix(6))", number: 7)
        let store = realDraftsDirectory()
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let legacy = track(store.appendingPathComponent("\(reference.owner)_\(reference.repo)_\(reference.number).json"))
        // No `referenceKey` inside: the oldest shape, where the name was the
        // only record of which pull request this was.
        try Data(#"{"summary":"eight comments","event":"REQUEST_CHANGES"}"#.utf8).write(to: legacy)
        _ = track(store.appendingPathComponent(PRStoreFileName.json(for: reference)))
        // The marker is what makes the migration one-shot; drop it so this
        // test exercises the migration rather than a store already migrated.
        try? FileManager.default.removeItem(at: store.appendingPathComponent("filenames-hashed.marker"))

        guard case .decoded(let migrated) = DraftStore.read(for: reference) else {
            return XCTFail("The draft must still open after its file is renamed")
        }
        XCTAssertEqual(migrated.summary, "eight comments")
        XCTAssertEqual(migrated.event, .requestChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "It moved rather than being copied")
        XCTAssertEqual(
            migrated.referenceKey, reference.key,
            "The identity moves into the file, or the dashboard shelf loses it"
        )
        XCTAssertTrue(
            DraftStore.savedReviews(host: .dotCom).contains { $0.reference == reference },
            "And it is still on the shelf"
        )
    }

    /// T-050: the host directory was a base64 of the API root. Renaming it to
    /// `identityKey` has to bring the drafts inside it along.
    func testDraftsMoveWithTheHostDirectory() throws {
        let host = ForgeHost(
            forge: .gitlab, displayName: "Scratch GitLab",
            apiBaseURL: URL(string: "https://gitlab-\(UUID().uuidString.prefix(8)).example/api/v4")!,
            webBaseURL: URL(string: "https://gitlab.example")!,
            graphQLURL: URL(string: "https://gitlab.example/api/graphql")!
        )
        let reference = PRReference(owner: "group", repo: "project", number: 12)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reviewrr/drafts", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent(
            Data(host.apiBaseURL.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"),
            isDirectory: true
        )
        createdInRealStore.append(legacyDirectory)
        createdInRealStore.append(root.appendingPathComponent(host.identityKey, isDirectory: true))
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        var draft = ReviewDraft()
        draft.referenceKey = reference.key
        draft.summary = "on the appliance"
        try JSONEncoder().encode(draft).write(to: legacyDirectory.appendingPathComponent("group_project_12.json"))

        guard case .decoded(let migrated) = DraftStore.read(for: reference, host: host) else {
            return XCTFail("A draft in the base64 host directory must survive the rename")
        }
        XCTAssertEqual(migrated.summary, "on the appliance")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyDirectory.path),
            "The whole directory moves, so nothing is left behind to go stale"
        )
        XCTAssertTrue(DraftStore.savedReviews(host: host).contains { $0.reference == reference })
    }

    // MARK: - T-012: a failed save must not trap the reviewer

    @MainActor
    func testAFailedSaveDoesNotTrapTheReviewerInTheWorkspace() {
        let model = AppModel()
        model.saveDraftToDisk = { _, _, _ in throw CocoaError(.fileNoSuchFile) }
        model.reference = PRReference(owner: "platform/payments", repo: "api", number: 318)
        model.pullRequest = DemoFixture.pullRequest
        model.draft.summary = "Eight comments"

        model.closePR()

        XCTAssertNil(model.reference, "Leaving the workspace must not depend on a successful save")
        XCTAssertNil(model.pullRequest)
        XCTAssertNotNil(model.draftSaveError, "And the reviewer has to be told why")
        XCTAssertTrue(model.hasUnsavedDrafts, "The review is held rather than dropped on the way out")
    }

    @MainActor
    func testRetryingASaveClearsTheHeldDraftAndTheBanner() {
        let model = AppModel()
        var shouldFail = true
        var written: [ReviewDraft] = []
        model.saveDraftToDisk = { draft, _, _ in
            if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            written.append(draft)
        }
        model.reference = PRReference(owner: "platform/payments", repo: "api", number: 318)
        model.pullRequest = DemoFixture.pullRequest
        model.draft.summary = "Eight comments"
        model.closePR()
        XCTAssertTrue(model.hasUnsavedDrafts)

        shouldFail = false
        model.retryDraftSave()

        XCTAssertFalse(model.hasUnsavedDrafts, "Retry has to reach the draft the reviewer already navigated away from")
        XCTAssertNil(model.draftSaveError)
        XCTAssertEqual(written.map(\.summary), ["Eight comments"])
    }
}
