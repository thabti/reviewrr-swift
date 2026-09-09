import XCTest

/// Covers the pure logic behind the Conversation and Checks tabs: timeline
/// merge ordering, unresolved-count derivation, GraphQL thread payload
/// decoding, check-run/commit-status merge and rollup computation, and
/// outdated/unanchored partitioning. No network — every case here works
/// against hand-built values or a fixture string.
final class ConversationTests: XCTestCase {
    // MARK: - Fixtures

    private func user(_ login: String) -> GitHubUser {
        GitHubUser(login: login, avatarUrl: nil)
    }

    private func issueComment(id: Int, login: String, createdAt: Date, body: String = "hello") -> IssueComment {
        // IssueComment/Review/ReviewComment decode from GitHub JSON in
        // production; built directly here via their Codable round trip
        // isn't necessary — they're plain Codable structs with no custom
        // init, so memberwise construction through JSON is avoided by
        // decoding a tiny literal once and reusing the pattern would be
        // needless ceremony. Swift's memberwise initializer construction
        // isn't available for these (custom CodingKeys), so build through
        // JSON decoding instead.
        let json = """
        {"id": \(id), "user": {"login": "\(login)", "avatar_url": null}, "body": "\(body)", \
        "created_at": "\(Self.iso(createdAt))", "html_url": "https://github.com/acme/app/issues/1#issuecomment-\(id)"}
        """
        return try! GitHubAPI.decoder.decode(IssueComment.self, from: Data(json.utf8))
    }

    private func review(id: Int, login: String, state: ReviewState, submittedAt: Date?, body: String? = nil) -> Review {
        let submittedJSON = submittedAt.map { "\"\(Self.iso($0))\"" } ?? "null"
        let bodyJSON = body.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "user": {"login": "\(login)", "avatar_url": null}, "body": \(bodyJSON), \
        "state": "\(state.rawValue)", "submitted_at": \(submittedJSON)}
        """
        return try! GitHubAPI.decoder.decode(Review.self, from: Data(json.utf8))
    }

    private func reviewComment(
        id: Int, login: String, body: String, path: String, line: Int?, side: DiffSide?,
        inReplyTo: Int? = nil, createdAt: Date
    ) -> ReviewComment {
        let lineJSON = line.map(String.init) ?? "null"
        let sideJSON = side.map { "\"\($0.rawValue)\"" } ?? "null"
        let replyJSON = inReplyTo.map(String.init) ?? "null"
        let json = """
        {"id": \(id), "user": {"login": "\(login)", "avatar_url": null}, "body": "\(body)", \
        "path": "\(path)", "line": \(lineJSON), "original_line": \(lineJSON), "side": \(sideJSON), \
        "in_reply_to_id": \(replyJSON), "created_at": "\(Self.iso(createdAt))", \
        "html_url": "https://github.com/acme/app/pull/1#discussion_r\(id)"}
        """
        return try! GitHubAPI.decoder.decode(ReviewComment.self, from: Data(json.utf8))
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400)
    }

    // MARK: - Timeline merge ordering

    func testTimelineOrdersByOpeningTimestampAcrossAllThreeKinds() {
        let general = issueComment(id: 1, login: "alice", createdAt: day(2))
        let approved = review(id: 2, login: "bob", state: .approved, submittedAt: day(0))
        let thread = ConversationThread(
            rootId: 3, path: "a.swift", line: 10, startLine: nil, side: .right,
            isOutdated: false, isCollapsed: false, resolution: .unknown,
            comments: [
                ConversationComment(
                    id: 3, author: user("carol"), body: "fix this", createdAt: day(1), updatedAt: nil, url: ""
                )
            ]
        )

        let items = ConversationModel.buildTimeline(threads: [thread], issueComments: [general], reviews: [approved])

        XCTAssertEqual(items.map(\.id), ["review-2", "thread-3", "general-1"])
    }

    func testTimelineReplyDoesNotBumpThreadPastLaterItems() {
        // A thread opened on day 0 with a reply on day 5 must still sort by
        // its root's timestamp (day 0), not the reply's — otherwise an old
        // thread getting a late reply would jump to "now" in the timeline.
        let thread = ConversationThread(
            rootId: 10, path: "a.swift", line: 1, startLine: nil, side: .right,
            isOutdated: false, isCollapsed: false, resolution: .unknown,
            comments: [
                ConversationComment(id: 10, author: user("alice"), body: "root", createdAt: day(0), updatedAt: nil, url: ""),
                ConversationComment(id: 11, author: user("bob"), body: "reply", createdAt: day(5), updatedAt: nil, url: ""),
            ]
        )
        let laterComment = issueComment(id: 20, login: "carol", createdAt: day(3))

        let items = ConversationModel.buildTimeline(threads: [thread], issueComments: [laterComment], reviews: [])

        XCTAssertEqual(items.map(\.id), ["thread-10", "general-20"])
    }

    // MARK: - Filters

    func testFilterUnresolvedKeepsGeneralAndReviewsButDropsResolvedThreads() {
        let general = ConversationItem.general(issueComment(id: 1, login: "alice", createdAt: day(0)))
        let resolvedThread = ConversationThread(
            rootId: 1, path: "a.swift", line: 1, startLine: nil, side: .right,
            isOutdated: false, isCollapsed: false, resolution: .resolved(by: "bob"),
            comments: [ConversationComment(id: 1, author: user("carol"), body: "x", createdAt: day(0), updatedAt: nil, url: "")]
        )
        let unresolvedThread = resolvedThread.withResolution(.unresolved)
        let items = [general, .thread(resolvedThread), .thread(unresolvedThread)]

        let filtered = ConversationModel.filter(items, by: .unresolved, currentUserLogin: nil, reviews: [])

        XCTAssertTrue(filtered.contains(general))
        XCTAssertTrue(filtered.contains(.thread(unresolvedThread)))
        XCTAssertFalse(filtered.contains(.thread(resolvedThread)))
    }

    func testFilterMineMatchesAuthorAcrossAllThreeKinds() {
        let mine = ConversationItem.general(issueComment(id: 1, login: "me", createdAt: day(0)))
        let notMine = ConversationItem.general(issueComment(id: 2, login: "someone-else", createdAt: day(0)))
        let myReview = ConversationItem.review(review(id: 3, login: "me", state: .approved, submittedAt: day(0)))

        let filtered = ConversationModel.filter([mine, notMine, myReview], by: .mine, currentUserLogin: "me", reviews: [])

        XCTAssertEqual(Set(filtered.map(\.id)), Set(["general-1", "review-3"]))
    }

    func testFilterSinceLastReviewKeepsOnlyItemsAfterMyMostRecentReview() {
        let myOldReview = review(id: 1, login: "me", state: .commented, submittedAt: day(0))
        let myNewReview = review(id: 2, login: "me", state: .approved, submittedAt: day(5))
        let before = ConversationItem.general(issueComment(id: 3, login: "alice", createdAt: day(3)))
        let after = ConversationItem.general(issueComment(id: 4, login: "bob", createdAt: day(7)))

        let filtered = ConversationModel.filter(
            [before, after], by: .sinceLastReview, currentUserLogin: "me", reviews: [myOldReview, myNewReview]
        )

        XCTAssertEqual(filtered.map(\.id), ["general-4"])
    }

    func testLastReviewSubmittedAtIgnoresOtherReviewersAndNilLogin() {
        let mine = review(id: 1, login: "me", state: .approved, submittedAt: day(2))
        let theirs = review(id: 2, login: "them", state: .approved, submittedAt: day(9))

        XCTAssertEqual(ConversationModel.lastReviewSubmittedAt(by: "me", in: [mine, theirs]), day(2))
        XCTAssertNil(ConversationModel.lastReviewSubmittedAt(by: nil, in: [mine, theirs]))
    }

    // MARK: - Unresolved counts

    func testUnresolvedCountsGroupByPathAndTreatUnknownAsNeedingAttention() {
        func thread(path: String, resolution: ConversationThread.ResolutionState) -> ConversationThread {
            ConversationThread(
                rootId: Int.random(in: 1...Int.max), path: path, line: 1, startLine: nil, side: .right,
                isOutdated: false, isCollapsed: false, resolution: resolution, comments: []
            )
        }
        let threads = [
            thread(path: "a.swift", resolution: .unresolved),
            thread(path: "a.swift", resolution: .unresolved),
            thread(path: "a.swift", resolution: .resolved(by: "bob")),
            thread(path: "b.swift", resolution: .unknown), // unknown counts as needing attention
        ]

        let counts = ConversationModel.unresolvedCounts(fromThreads: threads)

        XCTAssertEqual(counts["a.swift"], 2)
        XCTAssertEqual(counts["b.swift"], 1)
    }

    // MARK: - Outdated / unanchored partitioning

    func testIsUnanchoredForOutdatedOrMissingLine() {
        let live = ConversationThread(
            rootId: 1, path: "a.swift", line: 5, startLine: nil, side: .right,
            isOutdated: false, isCollapsed: false, resolution: .unresolved, comments: []
        )
        let outdated = ConversationThread(
            rootId: 2, path: "a.swift", line: 5, startLine: nil, side: .right,
            isOutdated: true, isCollapsed: false, resolution: .unresolved, comments: []
        )
        let noLine = ConversationThread(
            rootId: 3, path: "a.swift", line: nil, startLine: nil, side: .right,
            isOutdated: false, isCollapsed: false, resolution: .unresolved, comments: []
        )

        XCTAssertFalse(live.isUnanchored)
        XCTAssertTrue(outdated.isUnanchored)
        XCTAssertTrue(noLine.isUnanchored)

        let partitioned = [live, outdated, noLine].filter { !$0.isUnanchored }
        XCTAssertEqual(partitioned.map(\.rootId), [1])
    }

    // MARK: - GraphQL thread payload decoding

    func testDecodesGraphQLReviewThreadsFixture() throws {
        let json = """
        {
          "repository": {
            "pullRequest": {
              "reviewThreads": {
                "nodes": [
                  {
                    "id": "RT_kwDOA1",
                    "isResolved": true,
                    "isOutdated": false,
                    "isCollapsed": true,
                    "resolvedBy": { "login": "alice" },
                    "comments": { "nodes": [ { "databaseId": 101 }, { "databaseId": 102 } ] }
                  },
                  {
                    "id": "RT_kwDOA2",
                    "isResolved": false,
                    "isOutdated": true,
                    "isCollapsed": false,
                    "resolvedBy": null,
                    "comments": { "nodes": [ { "databaseId": 201 } ] }
                  }
                ]
              }
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(ThreadsClient.ThreadsQueryResult.self, from: Data(json.utf8))
        let states = ThreadsClient.threadStates(from: decoded)

        XCTAssertEqual(states?.count, 2)
        XCTAssertEqual(states?[0].nodeId, "RT_kwDOA1")
        XCTAssertEqual(states?[0].isResolved, true)
        XCTAssertEqual(states?[0].isCollapsed, true)
        XCTAssertEqual(states?[0].resolvedByLogin, "alice")
        XCTAssertEqual(states?[0].commentDatabaseIds, [101, 102])

        XCTAssertEqual(states?[1].isResolved, false)
        XCTAssertEqual(states?[1].isOutdated, true)
        XCTAssertNil(states?[1].resolvedByLogin)
    }

    func testDecodingReturnsNilWhenPullRequestNodeIsMissing() throws {
        let json = """
        { "repository": { "pullRequest": null } }
        """
        let decoded = try JSONDecoder().decode(ThreadsClient.ThreadsQueryResult.self, from: Data(json.utf8))
        XCTAssertNil(ThreadsClient.threadStates(from: decoded))
    }

    // MARK: - Merging REST threads with GraphQL state

    func testMergeAttachesResolutionByMatchingCommentDatabaseId() {
        let root = reviewComment(id: 101, login: "carol", body: "please fix", path: "a.swift", line: 12, side: .right, createdAt: day(0))
        let restThread = ReviewThread(rootId: 101, path: "a.swift", line: 12, side: .right, isOutdated: false, comments: [root])
        let state = ThreadsClient.ThreadState(
            nodeId: "RT_1", isResolved: true, isOutdated: false, isCollapsed: false,
            resolvedByLogin: "dave", commentDatabaseIds: [101]
        )

        let (threads, nodeIds) = ThreadsClient.merge(restThreads: [restThread], states: [state])

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].resolution, .resolved(by: "dave"))
        XCTAssertTrue(threads[0].isResolved)
        XCTAssertEqual(nodeIds[101], "RT_1")
    }

    func testMergeDegradesToUnknownWhenGraphQLUnavailable() {
        let root = reviewComment(id: 202, login: "carol", body: "x", path: "a.swift", line: 3, side: .right, createdAt: day(0))
        let restThread = ReviewThread(rootId: 202, path: "a.swift", line: 3, side: .right, isOutdated: false, comments: [root])

        let (threads, nodeIds) = ThreadsClient.merge(restThreads: [restThread], states: nil)

        XCTAssertEqual(threads[0].resolution, .unknown)
        XCTAssertFalse(threads[0].isResolved)
        XCTAssertTrue(nodeIds.isEmpty)
    }

    func testMergeDegradesToUnknownWhenThreadHasNoMatchingGraphQLNode() {
        let root = reviewComment(id: 303, login: "carol", body: "x", path: "a.swift", line: 3, side: .right, createdAt: day(0))
        let restThread = ReviewThread(rootId: 303, path: "a.swift", line: 3, side: .right, isOutdated: false, comments: [root])
        let unrelatedState = ThreadsClient.ThreadState(
            nodeId: "RT_9", isResolved: true, isOutdated: false, isCollapsed: false,
            resolvedByLogin: nil, commentDatabaseIds: [999]
        )

        let (threads, _) = ThreadsClient.merge(restThreads: [restThread], states: [unrelatedState])

        XCTAssertEqual(threads[0].resolution, .unknown)
    }

    // MARK: - Check-run / commit-status merge

    private func checkRun(
        id: String, name: String, appName: String? = nil, status: CheckStatus, conclusion: CheckConclusion?,
        startedAt: Date? = nil, completedAt: Date? = nil, source: CheckRun.Source
    ) -> CheckRun {
        CheckRun(
            id: id, name: name, appName: appName, status: status, conclusion: conclusion,
            startedAt: startedAt, completedAt: completedAt, detailsURL: nil,
            outputTitle: nil, outputSummary: nil, source: source
        )
    }

    func testChecksMergeDropsLegacyStatusDuplicatedByARicherCheckRun() {
        let checkRuns = [checkRun(id: "checkrun-1", name: "build", status: .completed, conclusion: .success, source: .checkRun)]
        let legacy = [
            checkRun(id: "status-1", name: "build", status: .completed, conclusion: .success, source: .legacyStatus),
            checkRun(id: "status-2", name: "deploy/preview", status: .completed, conclusion: .success, source: .legacyStatus),
        ]

        let merged = ChecksClient.merge(checkRuns: checkRuns, legacyStatuses: legacy)

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.id == "checkrun-1" })
        XCTAssertTrue(merged.contains { $0.id == "status-2" })
        XCTAssertFalse(merged.contains { $0.id == "status-1" })
    }

    func testChecksMergeSortsNewestStartedFirst() {
        let older = checkRun(id: "a", name: "a", status: .completed, conclusion: .success, startedAt: day(0), source: .checkRun)
        let newer = checkRun(id: "b", name: "b", status: .completed, conclusion: .success, startedAt: day(5), source: .checkRun)

        let merged = ChecksClient.merge(checkRuns: [older, newer], legacyStatuses: [])

        XCTAssertEqual(merged.map(\.id), ["b", "a"])
    }

    func testMapLegacyStateCoversAllGitHubStates() {
        XCTAssertTrue(ChecksClient.mapLegacyState("success") == (.completed, .success))
        XCTAssertTrue(ChecksClient.mapLegacyState("failure") == (.completed, .failure))
        XCTAssertTrue(ChecksClient.mapLegacyState("error") == (.completed, .failure))
        XCTAssertTrue(ChecksClient.mapLegacyState("pending") == (.inProgress, nil))
    }

    // MARK: - Rollup computation

    func testRollupIsEmptyWithNoRuns() {
        XCTAssertEqual(CheckRollup.compute(from: []), .empty)
    }

    func testRollupSucceedsWhenEveryCompletedRunSucceeds() {
        let runs = [
            checkRun(id: "1", name: "build", status: .completed, conclusion: .success, source: .checkRun),
            checkRun(id: "2", name: "lint", status: .completed, conclusion: .neutral, source: .checkRun),
        ]
        let rollup = CheckRollup.compute(from: runs)

        XCTAssertEqual(rollup.overallState, .success)
        XCTAssertEqual(rollup.totalCount, 2)
        XCTAssertEqual(rollup.pendingCount, 0)
        XCTAssertNil(rollup.firstFailing)
    }

    func testRollupIsPendingWhenNothingFailedYetButSomeAreStillRunning() {
        let runs = [
            checkRun(id: "1", name: "build", status: .completed, conclusion: .success, source: .checkRun),
            checkRun(id: "2", name: "test", status: .inProgress, conclusion: nil, source: .checkRun),
        ]
        let rollup = CheckRollup.compute(from: runs)

        XCTAssertEqual(rollup.overallState, .pending)
        XCTAssertEqual(rollup.pendingCount, 1)
    }

    func testRollupFailsImmediatelyEvenWithOtherChecksStillRunning() {
        // A failure must outrank "still running" — GitHub surfaces a broken
        // build right away rather than waiting for every check to finish.
        let runs = [
            checkRun(id: "1", name: "build", status: .completed, conclusion: .failure, source: .checkRun),
            checkRun(id: "2", name: "test", status: .inProgress, conclusion: nil, source: .checkRun),
        ]
        let rollup = CheckRollup.compute(from: runs)

        XCTAssertEqual(rollup.overallState, .failure)
        XCTAssertEqual(rollup.firstFailing?.id, "1")
        XCTAssertEqual(rollup.countsByConclusion[.failure], 1)
    }
}
