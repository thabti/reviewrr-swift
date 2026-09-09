import XCTest

/// Benchmarks for the paths that run at scale: decoding a full PR sync,
/// parsing and highlighting a large diff, and filtering a big inbox.
///
/// These exist so a performance claim can be checked rather than asserted.
/// They are `measure` blocks without hard thresholds on purpose — a wall-clock
/// limit that passes on this machine would fail on a slower one, and a flaky
/// perf test gets disabled, which is worse than no test. Run them before and
/// after a change and compare the reported averages.
final class PerformanceTests: XCTestCase {
    // MARK: - Fixtures

    /// A PR list payload the size of a real sync of a busy repository. Every
    /// element carries four ISO-8601 timestamps, which is what makes this
    /// exercise the date-decoding path rather than just JSON parsing.
    private static func pullRequestListJSON(count: Int) -> Data {
        let items = (1...count).map { number in
            """
            {
              "id": \(number),
              "number": \(number),
              "title": "feat(EC-\(number)): a representative pull request title",
              "body": "Some description text.",
              "state": "open",
              "draft": false,
              "merged": false,
              "mergeable_state": "clean",
              "user": {"login": "author\(number % 20)", "avatar_url": "https://example.com/a.png"},
              "head": {"ref": "feature/\(number)", "sha": "head\(number)"},
              "base": {"ref": "main", "sha": "base\(number)"},
              "additions": \(number * 3),
              "deletions": \(number),
              "changed_files": \(number % 40),
              "commits": \(number % 12),
              "comments": \(number % 8),
              "review_comments": \(number % 5),
              "created_at": "2026-08-0\((number % 9) + 1)T10:00:00Z",
              "updated_at": "2026-09-0\((number % 9) + 1)T11:30:45.123Z",
              "merged_at": null,
              "closed_at": null,
              "html_url": "https://github.com/acme/web/pull/\(number)",
              "labels": [{"id": 1, "name": "backend", "color": "1d76db"}]
            }
            """
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    /// A patch with the shape the parser actually sees: many hunks, mixed
    /// additions, deletions, and context.
    private static func largePatch(hunks: Int, linesPerHunk: Int) -> String {
        var out: [String] = []
        for hunk in 0..<hunks {
            let start = hunk * linesPerHunk + 1
            out.append("@@ -\(start),\(linesPerHunk) +\(start),\(linesPerHunk) @@ func example\(hunk)()")
            for line in 0..<linesPerHunk {
                switch line % 4 {
                case 0: out.append("-    let old = compute(\(line))")
                case 1: out.append("+    let new = compute(\(line), cached: true)")
                case 2: out.append("     // unchanged context line \(line)")
                default: out.append("     doSomething(with: value\(line))")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private func inboxRows(_ count: Int) -> [InboxPR] {
        (1...count).map(Self.inboxRow(number:))
    }

    /// Built field-by-field with pre-computed locals: a single initializer
    /// call with two dozen interpolated arguments is slow enough to
    /// type-check that the compiler refuses it outright.
    private static func inboxRow(number: Int) -> InboxPR {
        let merged = number % 7 == 0
        let repo = "repo" + String(number % 6)
        let title = "feat(EC-" + String(number) + "): representative title for row " + String(number)
        let author = "author" + String(number % 25)
        let reviewers: [String] = number % 3 == 0 ? ["reviewer1", "reviewer2"] : []
        let created = Date(timeIntervalSince1970: 1_700_000_000 + Double(number))
        let updated = Date(timeIntervalSince1970: 1_700_500_000 + Double(number))
        let labels = [GitHubLabel(id: 1, name: "backend", color: "1d76db")]
        return InboxPR(
            host: .dotCom,
            owner: "acme",
            repo: repo,
            number: number,
            title: title,
            authorLogin: author,
            authorAvatarURL: nil,
            state: merged ? .merged : .open,
            isMerged: merged,
            createdAt: created,
            updatedAt: updated,
            commentCount: number % 9,
            labels: labels,
            requestedReviewers: reviewers,
            reviewDecision: .none,
            ciState: .success,
            additions: number * 3,
            deletions: number,
            changedFiles: number % 40,
            headRef: "feature/" + String(number),
            headSha: "sha" + String(number),
            source: .project,
            buckets: []
        )
    }

    // MARK: - Decoding a full sync

    func testDecodePullRequestListPerformance() throws {
        let json = Self.pullRequestListJSON(count: 200)
        measure {
            for _ in 0..<5 {
                _ = try? GitHubAPI.decoder.decode([PullRequest].self, from: json)
            }
        }
    }

    func testDecodeCorrectnessAcrossBothTimestampShapes() throws {
        // Guards the optimization the benchmark motivates: whatever caches
        // the formatters must still parse both fractional and whole-second
        // timestamps, which GitHub mixes in one payload.
        let decoded = try GitHubAPI.decoder.decode([PullRequest].self, from: Self.pullRequestListJSON(count: 3))
        XCTAssertEqual(decoded.count, 3)
        for pr in decoded {
            XCTAssertGreaterThan(pr.updatedAt.timeIntervalSince1970, 0)
            XCTAssertGreaterThan(pr.createdAt.timeIntervalSince1970, 0)
        }
    }

    // MARK: - Diff pipeline

    func testParseLargePatchPerformance() {
        let patch = Self.largePatch(hunks: 40, linesPerHunk: 60)
        measure {
            _ = DiffParser.parse(filename: "Sources/Example.swift", patch: patch)
        }
    }

    func testSplitPairingPerformance() {
        let parsed = DiffParser.parse(filename: "Sources/Example.swift", patch: Self.largePatch(hunks: 40, linesPerHunk: 60))
        let lines = parsed.hunks.flatMap(\.lines)
        measure {
            _ = lines.pairedForSplitView()
        }
    }

    func testSyntaxHighlightPerformance() {
        let lines = (0..<400).map { index in
            "    private func handle\(index)(_ value: String) -> Int { return value.count + \(index) } // note"
        }
        measure {
            for line in lines {
                _ = SyntaxHighlighter.highlight(line, language: "swift")
            }
        }
    }

    func testWordDiffPerformance() {
        let pairs = (0..<400).map { index in
            (
                "let result = compute(value: \(index), retries: 3)",
                "let result = compute(value: \(index), retries: 5, cached: true)"
            )
        }
        measure {
            for (old, new) in pairs {
                _ = WordDiff.changedRanges(old: old, new: new)
            }
        }
    }

    /// Opening a pull request parses every changed file's patch before the
    /// workspace can render, so this is the cost of the open itself.
    func testParseEveryFileOfALargePRPerformance() {
        let files = (0..<200).map { index in
            PRFile(
                filename: "Sources/Feature\(index)/File\(index).swift",
                previousFilename: nil,
                status: .modified,
                additions: 30,
                deletions: 10,
                changes: 40,
                patch: Self.largePatch(hunks: 3, linesPerHunk: 20)
            )
        }
        measure {
            var parsed: [String: ParsedFile] = [:]
            for file in files {
                parsed[file.filename] = DiffParser.parse(filename: file.filename, patch: file.patch)
            }
            _ = parsed.count
        }
    }

    /// The same work, spread across cores and off the main actor — which is
    /// what actually happens when a pull request opens now.
    func testParseEveryFileConcurrentlyPerformance() async {
        let files = (0..<200).map { index in
            PRFile(
                filename: "Sources/Feature\(index)/File\(index).swift",
                previousFilename: nil, status: .modified,
                additions: 30, deletions: 10, changes: 40,
                patch: Self.largePatch(hunks: 3, linesPerHunk: 20)
            )
        }
        let clock = ContinuousClock()
        var total = Duration.zero
        let runs = 10
        for _ in 0..<runs {
            total += await clock.measure {
                _ = await withTaskGroup(of: (String, ParsedFile).self) { group in
                    for file in files {
                        group.addTask { (file.filename, DiffParser.parse(filename: file.filename, patch: file.patch)) }
                    }
                    var parsed: [String: ParsedFile] = [:]
                    for await pair in group { parsed[pair.0] = pair.1 }
                    return parsed
                }
            }
        }
        let average = total / runs
        print("concurrent whole-PR parse average: \(average)")
        XCTAssertLessThan(average, .milliseconds(500), "a regression this large would stall opening a PR")
    }

    // MARK: - Inbox at scale

    // MARK: - Typing

    /// One keystroke in the AI composer while the `@` picker is open, on a
    /// pull request the size this app is used on.
    ///
    /// The composer's `body` reads `matches` for the empty check, again for
    /// the row list, again for the height, and `paths` for the count — so
    /// whatever one lookup costs, a keystroke pays it four or five times.
    /// This measures the whole pass, because that is what the reviewer
    /// waits for between pressing a key and seeing the letter.
    @MainActor
    func testAskComposerKeystrokeWithPickerOpenPerformance() {
        let composer = AIAskComposerModel()
        composer.files = Self.workspaceFiles(675)
        measure {
            for index in 0..<50 {
                let text = "why does @Component\(index % 10)"
                composer.update(text: text, selection: NSRange(location: text.utf16.count, length: 0))
                _ = composer.matches.isEmpty
                _ = composer.matches.count
                _ = composer.matches
                _ = composer.paths.count
            }
        }
    }

    /// The same keystroke with no `@` in play — the ordinary case, where the
    /// picker is closed and the composer should be doing nothing but
    /// republishing the text.
    @MainActor
    func testAskComposerPlainKeystrokePerformance() {
        let composer = AIAskComposerModel()
        composer.files = Self.workspaceFiles(675)
        composer.taggedPaths = Array(composer.paths.prefix(5))
        measure {
            for index in 0..<200 {
                let text = String(repeating: "a", count: index % 40) + " question"
                composer.update(text: text, selection: NSRange(location: text.utf16.count, length: 0))
                _ = composer.mentionRange
                // What `canSend` costs: every tagged path checked against
                // the file list, on every body evaluation.
                _ = composer.taggedPaths.allSatisfy { composer.paths.contains($0) }
            }
        }
    }

    func testInboxFilterSortGroupPerformance() {
        let rows = inboxRows(2_000)
        var filter = InboxFilter()
        filter.searchText = "representative"
        measure {
            let filtered = InboxFiltering.apply(filter, to: rows, localStatus: [:])
            let sorted = InboxFiltering.sorted(filtered, field: .updated)
            _ = InboxFiltering.groupedByReviewerBucket(sorted)
        }
    }

    // MARK: - The review workspace at 675 files

    /// The size of the pull request this app is actually used on. Everything
    /// the sidebar and the diff pane derive per filter change runs here:
    /// classification, the hidden-category tally, the filter pass, the tree
    /// build, the flatten, and the visible-file list the pane renders.
    private static func workspaceFiles(_ count: Int) -> [PRFile] {
        (0..<count).map { index in
            let path = "packages/module\(index % 40)/src/feature/Component\(index).tsx"
            return PRFile(
                filename: path, previousFilename: nil, status: .modified,
                additions: index % 37, deletions: index % 11, changes: index % 48,
                patch: "@@ -1,1 +1,1 @@\n-a\n+b"
            )
        }
    }

    @MainActor
    func testWorkspaceRefreshPerformance() {
        let files = Self.workspaceFiles(675)
        let model = WorkspaceModel()
        measure {
            // A fresh model per iteration: `refresh` short-circuits when its
            // inputs are unchanged, which is the point of the next test, not
            // this one.
            model.searchText = model.searchText.isEmpty ? " " : ""
            model.refresh(files: files)
        }
    }

    /// The sidebar and the diff pane both call `refresh` from the same five
    /// triggers, so half of all calls are duplicates. They must cost nothing.
    @MainActor
    func testWorkspaceRefreshNoOpPerformance() {
        let files = Self.workspaceFiles(675)
        let model = WorkspaceModel()
        model.refresh(files: files)
        measure {
            for _ in 0..<1_000 { model.refresh(files: files) }
        }
    }

    /// One screenful of split diff rows resolving their inline discussion,
    /// plus a screenful of tree rows resolving their comment badge — the two
    /// lookups that run per row, per `body`, on every change to `AppModel`.
    @MainActor
    func testInlineDiscussionLookupPerformance() {
        let files = Self.workspaceFiles(675)
        let model = WorkspaceModel()
        let user = GitHubUser(login: "octocat", avatarUrl: nil)
        let threads: [ReviewThread] = (0..<200).map { index in
            let path = files[index % files.count].filename
            let line = index % 90 + 1
            let comment = ReviewComment(
                id: index, user: user, body: "note", path: path, line: line, originalLine: line,
                side: .right, inReplyToId: nil, createdAt: Date(), htmlUrl: "https://example.com"
            )
            return ReviewThread(rootId: index, path: path, line: line, side: .right, isOutdated: false, comments: [comment])
        }
        let drafts: [DraftComment] = (0..<25).map { index in
            DraftComment(path: files[index].filename, line: index * 3 + 1, side: .right, body: "d", headSha: "sha")
        }
        measure {
            for row in 1...45 {
                _ = model.inlineThreads(in: threads, path: files[0].filename, line: row, side: .left)
                _ = model.inlineThreads(in: threads, path: files[0].filename, line: row, side: .right)
                _ = model.inlineDrafts(in: drafts, path: files[0].filename, line: row, side: .right)
            }
            for index in 0..<30 {
                _ = model.commentBadge(path: files[index].filename, threads: threads, drafts: drafts)
            }
        }
    }

    /// Pairing a large file's hunks for the split/unified renderers. Both
    /// layouts do this to build their rows, and both used to do it inside
    /// `body`; the memo turns it into an array-identity comparison.
    @MainActor
    func testPairedRowMemoPerformance() {
        let parsed = DiffParser.parse(filename: "Sources/Example.swift", patch: Self.largePatch(hunks: 40, linesPerHunk: 60))
        let model = WorkspaceModel()
        measure {
            for _ in 0..<20 {
                for (index, hunk) in parsed.hunks.enumerated() {
                    _ = model.pairedRows(path: "Sources/Example.swift", hunkIndex: index, lines: hunk.lines)
                }
            }
        }
    }

    @MainActor
    func testReviewProgressPerformance() {
        let files = Self.workspaceFiles(675)
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let viewed = Set(files.prefix(300).map(\.filename))
        measure {
            // Recomputed on every evaluation of the sidebar's `body`.
            for _ in 0..<20 {
                _ = ReviewProgressCalculator.progress(files: files, classifications: classifications, viewedFiles: viewed)
            }
        }
    }

    // MARK: - Per-row work in a scroll

    /// Tab expansion happens once, at parse time.
    ///
    /// It used to run inside `body`: 1.4µs per line to scan for tabs, twice
    /// per split row (once for the text, once for the word-diff comparison),
    /// on every frame that materialized a row. This asserts the expansion is
    /// on the parsed line, so a `body` only reads it.
    func testDiffLinesCarryTheirExpandedText() {
        let parsed = DiffParser.parse(
            filename: "Sources/Example.swift",
            patch: "@@ -1,2 +1,2 @@\n-\tlet old = 1\n+\tlet new = 2"
        )
        let lines = parsed.hunks.flatMap(\.lines)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertEqual(line.displayText, DiffText.expandingTabs(line.text))
            XCTAssertFalse(line.displayText.contains("\t"), "a body must never have to expand tabs itself")
        }
    }

    /// Hunk headers show "+n −m", and the tally is stored rather than counted.
    /// Two `filter` passes over the hunk's lines per header, per `body`, is
    /// two allocations per visible hunk per frame.
    func testHunkTalliesArePrecomputed() {
        let parsed = DiffParser.parse(filename: "Sources/Example.swift", patch: Self.largePatch(hunks: 3, linesPerHunk: 40))
        XCTAssertFalse(parsed.hunks.isEmpty)
        for hunk in parsed.hunks {
            XCTAssertEqual(hunk.additions, hunk.lines.filter { $0.kind == .addition }.count)
            XCTAssertEqual(hunk.deletions, hunk.lines.filter { $0.kind == .deletion }.count)
        }
    }

    /// The scroll-target id a row builds every time it is materialized.
    /// Thousands of these per second during a fling, so it has to stay pure
    /// string concatenation.
    func testDiffRowScrollIDPerformance() {
        measure {
            for hunk in 0..<40 {
                for row in 0..<200 {
                    _ = diffRowScrollID(path: "packages/module/src/Component.tsx", hunkIndex: hunk, rowID: row)
                }
            }
        }
    }

    /// Resolving a local agent CLI walks the filesystem, and the AI panel asks
    /// for it while building its view — so it must be memoized.
    ///
    /// Ten thousand lookups have to cost far less than ten thousand `stat`
    /// storms; the threshold is loose on purpose, because the point is the
    /// difference between "cached" and "not", not a wall-clock budget.
    func testAgentPathResolutionIsMemoized() {
        let spec = AIProviderRegistry.descriptor(for: AIProviderRegistry.codex.id).localAgent
        guard let spec else { return XCTFail("the codex provider should declare a local agent binary") }
        AgentEnvironment.invalidateResolvedPaths()
        let first = AgentEnvironment.resolvePath(for: spec)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10_000 { _ = AgentEnvironment.resolvePath(for: spec) }
        }
        XCTAssertLessThan(elapsed, .milliseconds(50), "resolvePath is hitting the filesystem on every call")
        XCTAssertEqual(AgentEnvironment.resolvePath(for: spec), first, "the memo must not change the answer")
    }

    func testCommandPaletteRankingPerformance() {
        // The palette rebuilds and ranks its whole command set on every
        // keystroke, and its set grows with the inbox and the file list.
        let commands = (0..<1_200).map { index in
            PaletteCommand(
                id: "cmd.\(index)",
                title: "Command number \(index) with a realistic title",
                subtitle: "Sources/Feature/Module\(index)/File\(index).swift",
                symbol: "circle",
                group: .files,
                keywords: ["file", "module\(index)"]
            ) {}
        }
        measure {
            _ = CommandMatcher.rank(commands, query: "mod42")
        }
    }
}
