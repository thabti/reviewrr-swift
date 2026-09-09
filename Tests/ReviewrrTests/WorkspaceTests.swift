import XCTest
import SwiftUI

private func makeFile(
    _ filename: String, additions: Int = 1, deletions: Int = 1, changes: Int? = nil,
    patch: String? = "@@ -1,1 +1,1 @@\n-a\n+b", status: PRFileStatus = .modified,
    previousFilename: String? = nil
) -> PRFile {
    PRFile(
        filename: filename, previousFilename: previousFilename, status: status,
        additions: additions, deletions: deletions, changes: changes ?? (additions + deletions), patch: patch
    )
}

final class FileClassifierTests: XCTestCase {
    func testClassifiesRealisticPathsAcrossEcosystems() {
        let cases: [(String, FileCategory)] = [
            ("Sources/Reviewrr/Views/DiffView.swift", .source),
            ("Tests/ReviewrrTests/WorkspaceTests.swift", .test),
            ("src/lib/utils_test.go", .test),
            ("api/user_test.py", .test),
            ("spec/user_spec.rb", .test),
            ("app/__tests__/Foo.test.tsx", .test),
            ("src/components/Button.tsx", .frontend),
            ("web/src/App.jsx", .frontend),
            ("styles/main.scss", .frontend),
            ("cmd/server/main.go", .backend),
            ("app/models/user.rb", .backend),
            ("src/server/handler.ts", .backend),
            ("src/index.ts", .source),
            ("docs/README.md", .docs),
            ("README.md", .docs),
            ("package.json", .config),
            ("tsconfig.json", .config),
            ("Package.swift", .config),
            ("Podfile", .config),
            ("package-lock.json", .lockfile),
            ("Package.resolved", .lockfile),
            ("pnpm-lock.yaml", .lockfile),
            ("Podfile.lock", .lockfile),
            ("Cargo.lock", .lockfile),
            ("go.sum", .lockfile),
            ("db/migrations/20230501120000_add_users.sql", .migration),
            ("db/migrate/20230501_add_users.rb", .migration),
            (".github/workflows/ci.yml", .infra),
            ("Dockerfile", .infra),
            ("infra/main.tf", .infra),
            ("docker-compose.yml", .infra),
            ("app/__snapshots__/foo.snap", .generated),
            ("dist/bundle.min.js", .generated),
            ("proto/service.pb.go", .generated),
            ("random/path/with/no/hints.xyz", .other),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(FileClassifier.category(for: path), expected, "path: \(path)")
        }
    }

    func testFormattingOnlyDetectsWhitespaceOnlyChange() {
        let patch = """
        @@ -1,3 +1,3 @@
        -  func foo() {
        -      return 1
        -  }
        +func foo() {
        +    return 1
        +}
        """
        XCTAssertTrue(FileClassifier.isFormattingOnly(patch: patch))
    }

    func testFormattingOnlyIsFalseWhenContentActuallyChanges() {
        let patch = """
        @@ -1,1 +1,1 @@
        -return 1
        +return 2
        """
        XCTAssertFalse(FileClassifier.isFormattingOnly(patch: patch))
    }

    func testFormattingOnlyIsFalseForNilOrEmptyPatch() {
        XCTAssertFalse(FileClassifier.isFormattingOnly(patch: nil))
        XCTAssertFalse(FileClassifier.isFormattingOnly(patch: ""))
    }

    func testClassifyDerivesAllSignals() {
        let file = makeFile("big.go", additions: 900, deletions: 0, patch: nil, status: .renamed, previousFilename: "old.go")
        let classification = FileClassifier.classify(file)
        XCTAssertEqual(classification.category, .backend)
        XCTAssertTrue(classification.isLargeFile)
        XCTAssertTrue(classification.isBinaryOrEmpty)
        XCTAssertTrue(classification.isRename)
    }
}

final class FileTreeBuilderTests: XCTestCase {
    func testCollapsesASingleChildDirectoryChain() {
        let files = [makeFile("a/b/c/d.txt")]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .treeOrder)

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a/b/c")
        XCTAssertTrue(tree[0].isDirectory)
        XCTAssertEqual(tree[0].children.count, 1)
        XCTAssertEqual(tree[0].children[0].name, "d.txt")
        XCTAssertFalse(tree[0].children[0].isDirectory)
    }

    func testDoesNotCollapseADirectoryWithMultipleChildren() {
        let files = [
            makeFile("src/lib/ai/foo.ts"),
            makeFile("src/lib/ai/bar.ts"),
            makeFile("src/other.ts"),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .treeOrder)

        // "src" has two children (the collapsed "lib/ai" directory and the
        // "other.ts" file) so it stays its own row rather than collapsing.
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "src")
        XCTAssertEqual(tree[0].children.count, 2)
        let collapsed = tree[0].children.first { $0.isDirectory }
        XCTAssertEqual(collapsed?.name, "lib/ai")
        XCTAssertEqual(collapsed?.children.count, 2)
    }

    func testAggregatesAdditionsAndDeletionsUpTheTree() {
        let files = [
            makeFile("src/a.ts", additions: 3, deletions: 1),
            makeFile("src/b.ts", additions: 2, deletions: 5),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .treeOrder)
        XCTAssertEqual(tree[0].additions, 5)
        XCTAssertEqual(tree[0].deletions, 6)
        XCTAssertEqual(tree[0].fileCount, 2)
    }

    func testMostChangedSortOrdersFilesByTotalChanges() {
        let files = [
            makeFile("small.ts", additions: 1, deletions: 0),
            makeFile("big.ts", additions: 50, deletions: 50),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .mostChanged)
        XCTAssertEqual(tree.map(\.name), ["big.ts", "small.ts"])
    }

    func testCategoryPrioritySortPutsApplicationCodeFirst() {
        let files = [
            makeFile("README.md"),
            makeFile("main.swift"),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .categoryPriority)
        XCTAssertEqual(tree.map(\.name), ["main.swift", "README.md"])
    }

    func testFlattenFilePathsIsDepthFirstInDisplayOrder() {
        let files = [makeFile("b.ts"), makeFile("a/z.ts")]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .treeOrder)
        // Directories sort before files at the same level in tree order.
        XCTAssertEqual(FileTreeBuilder.flattenFilePaths(tree), ["a/z.ts", "b.ts"])
    }
}

final class ReviewProgressTests: XCTestCase {
    func testComputesOverallAndPerCategoryFractions() {
        let files = [
            makeFile("a.swift"), makeFile("b.swift"), makeFile("README.md"),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let progress = ReviewProgressCalculator.progress(
            files: files, classifications: classifications, viewedFiles: ["a.swift"]
        )
        XCTAssertEqual(progress.overallViewed, 1)
        XCTAssertEqual(progress.overallTotal, 3)
        XCTAssertEqual(progress.overallFraction, 1.0 / 3.0, accuracy: 0.0001)

        let source = progress.byCategory.first { $0.category == .source }
        XCTAssertEqual(source?.viewed, 1)
        XCTAssertEqual(source?.total, 2)
        let docs = progress.byCategory.first { $0.category == .docs }
        XCTAssertEqual(docs?.viewed, 0)
        XCTAssertEqual(docs?.total, 1)
    }

    func testIgnoresCategoriesNotPresentInThePR() {
        let files = [makeFile("a.swift")]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let progress = ReviewProgressCalculator.progress(files: files, classifications: classifications, viewedFiles: [])
        XCTAssertEqual(progress.byCategory.count, 1)
    }

    /// The footer prints the overall fraction above the per-category rows.
    /// They are two readings of one number and must add up, whatever the
    /// mix of categories.
    func testOverallViewedIsTheSumOfTheCategoryRows() {
        let files = [
            makeFile("a.swift"), makeFile("b.swift"), makeFile("README.md"),
            makeFile("package-lock.json"), makeFile("Dockerfile"),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let progress = ReviewProgressCalculator.progress(
            files: files, classifications: classifications,
            viewedFiles: ["a.swift", "README.md", "package-lock.json"]
        )
        XCTAssertEqual(progress.overallViewed, progress.byCategory.reduce(0) { $0 + $1.viewed })
        XCTAssertEqual(progress.overallTotal, progress.byCategory.reduce(0) { $0 + $1.total })
        XCTAssertEqual(progress.overallViewed, 3)
    }

    /// Progress deliberately counts *every* changed file, including the
    /// categories the tree is hiding — so hiding lockfiles cannot quietly
    /// inflate "how much of this PR have I seen".
    func testCountsFilesThatTheTreeHides() {
        let files = [makeFile("a.swift"), makeFile("package-lock.json")]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let progress = ReviewProgressCalculator.progress(
            files: files, classifications: classifications, viewedFiles: ["a.swift"]
        )
        XCTAssertEqual(progress.overallTotal, 2)
        XCTAssertEqual(progress.overallFraction, 0.5, accuracy: 0.0001)
        XCTAssertNotNil(progress.byCategory.first { $0.category == .lockfile })
    }

    /// A path left over in `viewedFiles` from a previous head — a file that
    /// a force-push removed from the pull request — must not count towards
    /// a total it is no longer part of.
    func testViewedPathsNotInThePRDoNotInflateProgress() {
        let files = [makeFile("a.swift")]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let progress = ReviewProgressCalculator.progress(
            files: files, classifications: classifications, viewedFiles: ["a.swift", "gone.swift"]
        )
        XCTAssertEqual(progress.overallViewed, 1)
        XCTAssertEqual(progress.overallTotal, 1)
        XCTAssertEqual(progress.overallFraction, 1.0, accuracy: 0.0001)
    }
}

final class DiffNavigatorTests: XCTestCase {
    func testAdjacentFileClampsAtTheEnds() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(DiffNavigator.adjacentFile(to: "a", in: order, delta: 1), "b")
        XCTAssertEqual(DiffNavigator.adjacentFile(to: "c", in: order, delta: 1), "c")
        XCTAssertEqual(DiffNavigator.adjacentFile(to: "a", in: order, delta: -1), "a")
        XCTAssertEqual(DiffNavigator.adjacentFile(to: nil, in: order, delta: 1), "a")
    }

    func testNextAndPreviousAnchorOrderByFileThenLine() {
        let order = ["a.swift", "b.swift"]
        let anchors = [
            DiffAnchor(path: "b.swift", line: 5, side: .right),
            DiffAnchor(path: "a.swift", line: 10, side: .right),
            DiffAnchor(path: "a.swift", line: 2, side: .right),
        ]
        let first = DiffNavigator.nextAnchor(after: nil, in: anchors, order: order)
        XCTAssertEqual(first, DiffAnchor(path: "a.swift", line: 2, side: .right))

        let second = DiffNavigator.nextAnchor(after: first, in: anchors, order: order)
        XCTAssertEqual(second, DiffAnchor(path: "a.swift", line: 10, side: .right))

        let third = DiffNavigator.nextAnchor(after: second, in: anchors, order: order)
        XCTAssertEqual(third, DiffAnchor(path: "b.swift", line: 5, side: .right))

        // Already at the last anchor: stays put rather than wrapping.
        let stillThird = DiffNavigator.nextAnchor(after: third, in: anchors, order: order)
        XCTAssertEqual(stillThird, third)

        let backToSecond = DiffNavigator.previousAnchor(before: third, in: anchors, order: order)
        XCTAssertEqual(backToSecond, second)
    }

    // MARK: - Change navigation

    /// Two hunks, each opening with context — the shape every real diff has.
    private func changeNavigationHunks() -> [DiffHunk] {
        let patch = """
        @@ -8,6 +8,7 @@ func first() {
         context one
         context two
        -removed line
        +added line
         context three
        @@ -38,4 +39,5 @@ func second() {
         context
        +another added
         trailing
        """
        return DiffParser.parse(filename: "a.swift", patch: patch).hunks
    }

    /// The bug this pins: stepping to a hunk's `newStart` landed on the
    /// *context* line the hunk opens with, so "next change" highlighted an
    /// unchanged line two or three rows above the actual change.
    func testChangeAnchorsLandOnTheChangeNotTheHunkHeader() {
        let hunks = changeNavigationHunks()
        XCTAssertEqual(hunks.count, 2)
        // The hunk starts at line 8; its first change is further down.
        XCTAssertEqual(hunks[0].newStart, 8)

        let anchors = DiffNavigator.changeAnchors(in: hunks, path: "a.swift")
        XCTAssertEqual(anchors.count, 2)
        XCTAssertNotEqual(anchors[0].line, hunks[0].newStart, "must not anchor to the hunk's opening context")
        XCTAssertGreaterThan(anchors[0].line ?? 0, hunks[0].newStart)
    }

    /// A removal has no new-side line, so the side has to travel with the
    /// number — anchoring it right would resolve to no row and the jump
    /// would silently do nothing.
    func testDeletionOnlyHunkAnchorsToTheLeftSide() {
        let patch = """
        @@ -10,4 +10,3 @@
         context
        -gone
         trailing
        """
        let hunks = DiffParser.parse(filename: "a.swift", patch: patch).hunks
        let change = DiffNavigator.firstChange(in: hunks[0])
        XCTAssertEqual(change?.side, .left)
        XCTAssertEqual(change?.line, 11, "the old-side number of the removed line")
    }

    /// The dead end: exhaustion used to be inferred from the target coming
    /// back equal to the cursor, because the old pair clamped to the last
    /// hunk. It now has its own answer, which is what lets the caller step
    /// into the next file.
    func testExhaustionIsReportedRatherThanClamped() {
        let anchors = DiffNavigator.changeAnchors(in: changeNavigationHunks(), path: "a.swift")
        let last = anchors.last?.line

        XCTAssertNil(
            DiffNavigator.nextChange(after: last, anchors: anchors),
            "past the last change there is nowhere left in this file"
        )
        XCTAssertNil(
            DiffNavigator.previousChange(before: anchors.first?.line, anchors: anchors),
            "before the first change there is nowhere left in this file"
        )
    }

    func testSteppingForwardAndBackThroughAFilesChanges() {
        let anchors = DiffNavigator.changeAnchors(in: changeNavigationHunks(), path: "a.swift")

        let first = DiffNavigator.nextChange(after: nil, anchors: anchors)
        XCTAssertEqual(first, anchors.first)

        let second = DiffNavigator.nextChange(after: first?.line, anchors: anchors)
        XCTAssertEqual(second, anchors.last)

        let backToFirst = DiffNavigator.previousChange(before: second?.line, anchors: anchors)
        XCTAssertEqual(backToFirst, anchors.first)
    }

    /// A hunk with no additions or removals is not a change to step to —
    /// a pure rename or mode change produces one.
    func testHunkWithNoChangedLinesYieldsNoAnchor() {
        let hunk = DiffHunk(
            id: 0, header: "", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            lines: [DiffLine(id: 0, kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "same")]
        )
        XCTAssertNil(DiffNavigator.firstChange(in: hunk))
        XCTAssertTrue(DiffNavigator.changeAnchors(in: [hunk], path: "a.swift").isEmpty)
    }

    /// Entering a file from a neighbour lands on its first change going
    /// forward and its last going back, rather than on whatever the cursor
    /// was left at during an earlier visit.
    @MainActor
    func testEnteringAFileLandsOnTheEdgeChangeForTheDirectionOfTravel() {
        let workspace = WorkspaceModel()
        let hunks = changeNavigationHunks()
        let anchors = DiffNavigator.changeAnchors(in: hunks, path: "a.swift")

        XCTAssertEqual(workspace.enterFile("a.swift", hunks: hunks, from: 1), anchors.first)
        XCTAssertEqual(workspace.enterFile("a.swift", hunks: hunks, from: -1), anchors.last)
        XCTAssertNil(workspace.enterFile("empty.swift", hunks: [], from: 1))
    }

    /// The cursor moves with the reviewer, so the bar can say "2/2" and the
    /// next press continues from where they are.
    @MainActor
    func testAdvancingUpdatesTheCursorAndReportsExhaustion() {
        let workspace = WorkspaceModel()
        let hunks = changeNavigationHunks()

        let first = workspace.advanceHunk(in: "a.swift", hunks: hunks, delta: 1)
        XCTAssertNotNil(first)
        XCTAssertEqual(workspace.hunkCursor["a.swift"], first?.line)

        let second = workspace.advanceHunk(in: "a.swift", hunks: hunks, delta: 1)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second?.line, first?.line)

        // Third press has nowhere to go in this file — the caller steps into
        // the next one.
        XCTAssertNil(workspace.advanceHunk(in: "a.swift", hunks: hunks, delta: 1))
    }

    /// The bar asks for these from its `body` on every model change, so
    /// repeated calls with unchanged input must not rebuild them.
    @MainActor
    func testCommentAnchorsAreMemoizedByTheirSource() {
        let workspace = WorkspaceModel()
        let thread = ReviewThread(
            rootId: 1, path: "a.swift", line: 12, side: .right, isOutdated: false, comments: []
        )
        let draft = DraftComment(path: "b.swift", line: 3, side: .right, body: "x", headSha: "sha")

        let first = workspace.commentAnchors(threads: [thread], drafts: [draft])
        XCTAssertEqual(first.count, 2)
        // Same input, same value — and the identical array, since nothing
        // was recomputed.
        XCTAssertEqual(workspace.commentAnchors(threads: [thread], drafts: [draft]), first)
        // Changed input rebuilds.
        XCTAssertEqual(workspace.commentAnchors(threads: [], drafts: [draft]).count, 1)
    }

    func testRowIdentityResolvesLineAndSideToAPairedRow() {
        let patch = """
        @@ -1,3 +1,3 @@
         context
        -old line
        +new line
         trailing
        """
        let parsed = DiffParser.parse(filename: "a.ts", patch: patch)
        let identity = DiffNavigator.rowIdentity(forLine: 2, side: .right, hunks: parsed.hunks)
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.hunkIndex, 0)

        XCTAssertNil(DiffNavigator.rowIdentity(forLine: nil, side: .right, hunks: parsed.hunks))
        XCTAssertNil(DiffNavigator.rowIdentity(forLine: 999, side: .right, hunks: parsed.hunks))
    }
}

final class WordDiffTests: XCTestCase {
    func testTokenizeReconstructsTheOriginalLine() {
        let line = "let x = compute(a, b) // note"
        let tokens = WordDiff.tokenize(line)
        XCTAssertEqual(tokens.joined(), line)
    }

    func testChangedRangesTrimsCommonPrefixAndSuffix() {
        let old = "let result = compute(1)"
        let new = "let result = compute(2)"
        let (oldRange, newRange) = WordDiff.changedRanges(old: old, new: new)
        XCTAssertEqual(oldRange.map { String(old[$0]) }, "1")
        XCTAssertEqual(newRange.map { String(new[$0]) }, "2")
    }

    func testChangedRangesIsNilForIdenticalLines() {
        let (oldRange, newRange) = WordDiff.changedRanges(old: "same", new: "same")
        XCTAssertNil(oldRange)
        XCTAssertNil(newRange)
    }

    func testChangedRangesCoversWholeLineWhenNothingIsShared() {
        let (oldRange, newRange) = WordDiff.changedRanges(old: "foo", new: "bar")
        XCTAssertEqual(oldRange, "foo".startIndex..<"foo".endIndex)
        XCTAssertEqual(newRange, "bar".startIndex..<"bar".endIndex)
    }

    func testChangedRangesSkipsOverlongLines() {
        let long = String(repeating: "x", count: WordDiff.maxLineLength + 1)
        let (oldRange, newRange) = WordDiff.changedRanges(old: long, new: long + "y")
        XCTAssertNil(oldRange)
        XCTAssertNil(newRange)
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private func color(of substring: String, in source: String, language: String) -> Color? {
        let attributed = SyntaxHighlighter.highlight(source, language: language)
        guard let sourceRange = source.range(of: substring),
              let attrRange = Range(sourceRange, in: attributed)
        else { return nil }
        return attributed[attrRange].foregroundColor
    }

    func testLanguageIsInferredFromFileExtension() {
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "Foo.swift"), "swift")
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "a/b/Component.tsx"), "typescript")
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "main.go"), "go")
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "lib.rs"), "rust")
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "script.py"), "python")
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "unknownfile"), "plain")
    }

    func testSwiftKeywordStringAndCommentBoundaries() {
        let line = #"let name = "world" // greet"#
        XCTAssertEqual(color(of: "let", in: line, language: "swift"), SyntaxHighlighter.color(for: .keyword))
        XCTAssertEqual(color(of: "\"world\"", in: line, language: "swift"), SyntaxHighlighter.color(for: .string))
        XCTAssertEqual(color(of: "// greet", in: line, language: "swift"), SyntaxHighlighter.color(for: .comment))
    }

    func testPythonKeywordAndCommentBoundaries() {
        let line = "def foo():  # docstring"
        XCTAssertEqual(color(of: "def", in: line, language: "python"), SyntaxHighlighter.color(for: .keyword))
        XCTAssertEqual(color(of: "# docstring", in: line, language: "python"), SyntaxHighlighter.color(for: .comment))
    }

    func testGoKeywordAndNumberBoundaries() {
        let line = "var count = 42"
        XCTAssertEqual(color(of: "var", in: line, language: "go"), SyntaxHighlighter.color(for: .keyword))
        XCTAssertEqual(color(of: "42", in: line, language: "go"), SyntaxHighlighter.color(for: .number))
    }

    func testPlainLanguageAppliesNoStyling() {
        let attributed = SyntaxHighlighter.highlight("just some text", language: "plain")
        for run in attributed.runs {
            XCTAssertNil(run.foregroundColor)
        }
    }

    func testOverlongLinesAreLeftUnstyled() {
        let long = String(repeating: "let x = 1; ", count: 300)
        let attributed = SyntaxHighlighter.highlight(long, language: "swift")
        for run in attributed.runs {
            XCTAssertNil(run.foregroundColor)
        }
    }
}

// MARK: - Tree aggregate accuracy

private func leafDescendants(of node: FileTreeNode) -> [FileTreeNode] {
    node.children.isEmpty ? (node.file == nil ? [] : [node]) : node.children.flatMap(leafDescendants(of:))
}

final class FileTreeAggregateTests: XCTestCase {
    /// Every number a directory row prints — the file count and the +/−
    /// pair — has to be exactly the sum over the leaves the tree actually
    /// shows beneath it, at every level, including through a collapsed
    /// single-child chain.
    func testDirectoryCountsEqualTheirVisibleLeaves() {
        let files = [
            makeFile("src/deep/only/child.ts", additions: 4, deletions: 2),
            makeFile("src/app/a.ts", additions: 3, deletions: 1),
            makeFile("src/app/b.ts", additions: 10, deletions: 0),
            makeFile("README.md", additions: 1, deletions: 1),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: files, classifications: classifications, sortOrder: .treeOrder)

        func check(_ node: FileTreeNode) {
            let leaves = leafDescendants(of: node)
            XCTAssertEqual(node.fileCount, leaves.count, "fileCount for \(node.name)")
            XCTAssertEqual(node.additions, leaves.reduce(0) { $0 + $1.additions }, "additions for \(node.name)")
            XCTAssertEqual(node.deletions, leaves.reduce(0) { $0 + $1.deletions }, "deletions for \(node.name)")
            node.children.forEach(check)
        }
        tree.forEach(check)

        XCTAssertEqual(tree.reduce(0) { $0 + $1.fileCount }, files.count)
        XCTAssertEqual(FileTreeBuilder.flattenFilePaths(tree).count, files.count)
    }

    /// A filtered-out file must not survive in any directory's totals — the
    /// tree's "N of M" and the numbers beside each folder have to describe
    /// the same set of rows.
    func testDirectoryCountsExcludeFilteredFiles() {
        let files = [
            makeFile("src/a.ts", additions: 3, deletions: 1),
            makeFile("src/b.ts", additions: 5, deletions: 5),
        ]
        let classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.classify($0)) })
        let tree = FileTreeBuilder.build(files: [files[0]], classifications: classifications, sortOrder: .treeOrder)
        XCTAssertEqual(tree.first?.fileCount, 1)
        XCTAssertEqual(tree.first?.additions, 3)
        XCTAssertEqual(tree.first?.deletions, 1)
    }
}

// MARK: - WorkspaceModel derivations

@MainActor
final class WorkspaceModelTests: XCTestCase {
    private func thread(_ path: String, line: Int?, side: DiffSide?, rootId: Int = 1) -> ReviewThread {
        let user = GitHubUser(login: "octocat", avatarUrl: nil)
        let comment = ReviewComment(
            id: rootId, user: user, body: "note", path: path, line: line, originalLine: line,
            side: side, inReplyToId: nil, createdAt: Date(), htmlUrl: "https://example.com"
        )
        return ReviewThread(rootId: rootId, path: path, line: line, side: side, isOutdated: line == nil, comments: [comment])
    }

    private func draft(_ path: String, line: Int, side: DiffSide) -> DraftComment {
        DraftComment(path: path, line: line, side: side, body: "draft", headSha: "sha")
    }

    // MARK: Multi-line comment selection

    /// Dragging down the gutter selects a range — "this whole block is the
    /// problem" instead of the same note left on six consecutive lines.
    func testDraggingSelectsARangeAndReversingKeepsItAscending() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 40)
        model.extendLineSelection(path: "a.swift", side: .right, to: 46)
        XCTAssertEqual(model.lineSelection?.range, 40...46)

        // Dragging back up past the start selects upward rather than
        // inverting into an empty or backwards range.
        model.extendLineSelection(path: "a.swift", side: .right, to: 33)
        XCTAssertEqual(model.lineSelection?.range, 33...40)
        XCTAssertTrue(model.lineSelection?.isMultiLine == true)
    }

    func testSelectionDoesNotSpanFilesOrSides() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 10)

        // GitHub will not accept a range across two files, and a range across
        // both sides of a split diff means nothing to whoever reads it.
        model.extendLineSelection(path: "b.swift", side: .right, to: 12)
        XCTAssertEqual(model.lineSelection?.path, "b.swift")
        XCTAssertEqual(model.lineSelection?.range, 12...12)

        model.extendLineSelection(path: "b.swift", side: .left, to: 20)
        XCTAssertEqual(model.lineSelection?.side, .left)
        XCTAssertEqual(model.lineSelection?.range, 20...20)
    }

    func testOnlyLinesInsideTheRangeReadAsSelected() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 5)
        model.extendLineSelection(path: "a.swift", side: .right, to: 8)

        XCTAssertTrue(model.isLineSelected(path: "a.swift", side: .right, line: 6))
        XCTAssertFalse(model.isLineSelected(path: "a.swift", side: .right, line: 9))
        XCTAssertFalse(model.isLineSelected(path: "a.swift", side: .left, line: 6))
        XCTAssertFalse(model.isLineSelected(path: "b.swift", side: .right, line: 6))
        XCTAssertFalse(model.isLineSelected(path: "a.swift", side: .right, line: nil))
    }

    /// The comment box goes below the code it is about — under the last line
    /// of a dragged range, never in the middle of it.
    func testComposerOpensUnderTheLastLineOfTheRange() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 20)
        model.extendLineSelection(path: "a.swift", side: .right, to: 26)

        // Clicking "+" anywhere inside the range puts the box at the bottom.
        model.openComposer(path: "a.swift", side: .right, line: 22)
        XCTAssertTrue(model.isComposerOpen(path: "a.swift", side: .right, line: 26))
        XCTAssertFalse(model.isComposerOpen(path: "a.swift", side: .right, line: 22))
    }

    func testTheComposerFollowsTheBottomOfAGrowingDrag() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 5)
        model.openComposer(path: "a.swift", side: .right, line: 5)

        model.extendLineSelection(path: "a.swift", side: .right, to: 9)
        XCTAssertTrue(model.isComposerOpen(path: "a.swift", side: .right, line: 9))

        // Dragging back up brings it with you.
        model.extendLineSelection(path: "a.swift", side: .right, to: 6)
        XCTAssertTrue(model.isComposerOpen(path: "a.swift", side: .right, line: 6))
    }

    func testASingleLineCommentOpensOnThatLine() {
        let model = WorkspaceModel()
        model.openComposer(path: "a.swift", side: .left, line: 12)
        XCTAssertTrue(model.isComposerOpen(path: "a.swift", side: .left, line: 12))
        XCTAssertFalse(model.isComposerOpen(path: "a.swift", side: .right, line: 12))
        model.closeComposer()
        XCTAssertFalse(model.isComposerOpen(path: "a.swift", side: .left, line: 12))
    }

    /// A drag is held inside the hunk it started in.
    ///
    /// GitHub rejects a comment whose range reaches outside the diff — and it
    /// rejects the *whole* review, not the one comment — so this is the
    /// difference between a review that submits and one that 422s with no
    /// indication of which draft is at fault.
    func testSelectionCannotLeaveTheHunkItStartedIn() {
        let model = WorkspaceModel()
        model.setSelectableRuns([420...460, 700...740], path: "a.swift", side: .right)

        model.beginLineSelection(path: "a.swift", side: .right, line: 430)
        // A drag flung upward past the top of the file.
        model.extendLineSelection(path: "a.swift", side: .right, to: 1)
        XCTAssertEqual(model.lineSelection?.range, 420...430)

        // And downward into the next hunk.
        model.extendLineSelection(path: "a.swift", side: .right, to: 999)
        XCTAssertEqual(model.lineSelection?.range, 430...460)
    }

    func testSelectionWithoutKnownRunsStillRefusesLineZero() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 5)
        model.extendLineSelection(path: "a.swift", side: .right, to: -20)
        XCTAssertEqual(model.lineSelection?.range.lowerBound, 1)
    }

    /// A composer the reviewer has typed into must not be dragged away by a
    /// selection somewhere else: its text is keyed by line, so the box would
    /// reappear empty and the typing would be unreachable.
    func testANewSelectionElsewhereLeavesAnOpenComposerAlone() {
        let model = WorkspaceModel()
        model.openComposer(path: "a.swift", side: .right, line: 40)

        model.beginLineSelection(path: "a.swift", side: .right, line: 300)
        model.extendLineSelection(path: "a.swift", side: .right, to: 306)

        XCTAssertTrue(model.isComposerOpen(path: "a.swift", side: .right, line: 40),
                      "the composer stays where the reviewer opened it")
        XCTAssertFalse(model.isComposerOpen(path: "a.swift", side: .right, line: 306))
    }

    func testSwitchingFilesDropsTheSelectionAndComposer() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 10)
        model.openComposer(path: "a.swift", side: .right, line: 10)

        model.fileDidChange(to: "b.swift")
        XCTAssertNil(model.lineSelection)
        XCTAssertFalse(model.isComposerOpen(path: "a.swift", side: .right, line: 10))
    }

    func testReturningToTheSameFileKeepsTheSelection() {
        let model = WorkspaceModel()
        model.beginLineSelection(path: "a.swift", side: .right, line: 10)
        model.fileDidChange(to: "a.swift")
        XCTAssertNotNil(model.lineSelection)
    }

    // MARK: Lazy patch parsing

    /// Patches are parsed when a file is opened, not all 675 up front — that
    /// cost 110ms of CPU and retained 13.6MB to render the one file the
    /// reviewer is actually looking at. This is the part that decides what to
    /// keep as they move on.
    func testParsedBudgetKeepsRecentFilesAndDropsTheOldest() {
        var budget = ParsedDiffBudget(limit: 3)

        XCTAssertTrue(budget.touch("a").isEmpty)
        XCTAssertTrue(budget.touch("b").isEmpty)
        XCTAssertTrue(budget.touch("c").isEmpty)
        XCTAssertEqual(budget.touch("d"), ["a"], "the least recently opened file is the one dropped")
        XCTAssertEqual(budget.recency, ["d", "c", "b"])
    }

    func testReopeningAFileMovesItBackToTheFront() {
        var budget = ParsedDiffBudget(limit: 3)
        _ = budget.touch("a")
        _ = budget.touch("b")
        _ = budget.touch("c")

        // Stepping back to "a" must not then evict it on the next new file.
        _ = budget.touch("a")
        XCTAssertEqual(budget.touch("d"), ["b"])
        XCTAssertEqual(budget.recency, ["d", "a", "c"])
    }

    func testParsedBudgetIsClearedWithThePullRequest() {
        var budget = ParsedDiffBudget(limit: 2)
        _ = budget.touch("a")
        budget.removeAll()
        XCTAssertTrue(budget.recency.isEmpty)
    }

    // MARK: Next unreviewed file

    /// `v` marks the open file viewed and opens the next one that still needs
    /// reading. Getting this wrong wastes the reviewer a keystroke per file —
    /// 675 of them on the pull request this app is built for.
    func testNextUnviewedSkipsFilesAlreadyViewed() {
        let model = WorkspaceModel()
        model.refresh(files: [makeFile("a.swift"), makeFile("b.swift"), makeFile("c.swift"), makeFile("d.swift")])

        let next = model.nextUnviewedPath(after: "a.swift", viewedFiles: ["b.swift", "c.swift"])
        XCTAssertEqual(next, "d.swift")
    }

    func testNextUnviewedWrapsBackToSomethingSkippedEarlier() {
        let model = WorkspaceModel()
        model.refresh(files: [makeFile("a.swift"), makeFile("b.swift"), makeFile("c.swift")])

        // Everything after "c" is viewed, but "a" was skipped — silently doing
        // nothing here reads as a broken key.
        let next = model.nextUnviewedPath(after: "c.swift", viewedFiles: ["b.swift", "c.swift"])
        XCTAssertEqual(next, "a.swift")
    }

    func testNextUnviewedFallsForwardWhenEverythingIsViewed() {
        let model = WorkspaceModel()
        model.refresh(files: [makeFile("a.swift"), makeFile("b.swift")])

        let next = model.nextUnviewedPath(after: "a.swift", viewedFiles: ["a.swift", "b.swift"])
        XCTAssertEqual(next, "b.swift")
    }

    func testNextUnviewedStartsAtTheTopWithNothingOpen() {
        let model = WorkspaceModel()
        model.refresh(files: [makeFile("a.swift"), makeFile("b.swift")])

        XCTAssertEqual(model.nextUnviewedPath(after: nil, viewedFiles: []), "a.swift")
        XCTAssertNil(WorkspaceModel().nextUnviewedPath(after: nil, viewedFiles: []))
    }

    // MARK: Per-hunk collapse

    func testHunkCollapseIsPerFileAndPerHunk() {
        let model = WorkspaceModel()
        model.toggleHunk(path: "a.swift", hunkIndex: 1)

        XCTAssertTrue(model.isHunkCollapsed(path: "a.swift", hunkIndex: 1))
        XCTAssertFalse(model.isHunkCollapsed(path: "a.swift", hunkIndex: 0))
        XCTAssertFalse(model.isHunkCollapsed(path: "b.swift", hunkIndex: 1))

        model.setHunks(collapsed: true, path: "a.swift", count: 3)
        XCTAssertTrue((0..<3).allSatisfy { model.isHunkCollapsed(path: "a.swift", hunkIndex: $0) })
        model.setHunks(collapsed: false, path: "a.swift", count: 3)
        XCTAssertTrue((0..<3).allSatisfy { !model.isHunkCollapsed(path: "a.swift", hunkIndex: $0) })
    }

    // MARK: Composer text

    /// Typed comment text used to live in the composer view's own state,
    /// inside the diff's lazy stack, so scrolling away destroyed it.
    func testComposerTextSurvivesOnTheModelAndClearsExplicitly() {
        let model = WorkspaceModel()
        model.setComposerText("half a thought", path: "a.swift", line: 12, side: .right)
        model.setComposerText("and another", path: "b.swift", line: 3, side: .left)

        XCTAssertEqual(model.composerText(path: "a.swift", line: 12, side: .right), "half a thought")
        model.clearComposer(path: "a.swift", line: 12, side: .right)
        XCTAssertEqual(model.composerText(path: "a.swift", line: 12, side: .right), "")
        XCTAssertEqual(model.composerText(path: "b.swift", line: 3, side: .left), "and another")

        // A different pull request opening drops every half-written comment.
        model.clearAllComposerText()
        XCTAssertEqual(model.composerText(path: "b.swift", line: 3, side: .left), "")
    }

    // MARK: Visible file set

    func testVisibleFilesMatchTheTreeExactlyAndInOrder() {
        let model = WorkspaceModel()
        model.hiddenCategories = [.lockfile]
        let files = [
            makeFile("b.swift"), makeFile("a/z.swift"), makeFile("package-lock.json"),
        ]
        model.refresh(files: files)

        XCTAssertEqual(model.visibleFiles.map(\.filename), model.orderedVisiblePaths)
        XCTAssertEqual(model.orderedVisiblePaths, ["a/z.swift", "b.swift"])
        XCTAssertEqual(model.hiddenCountByCategory[.lockfile], 1)
        // Classification covers every changed file, hidden ones included —
        // review progress is counted over all of them.
        XCTAssertEqual(model.classifications.count, files.count)
    }

    func testSearchNarrowsBothTheTreeAndTheVisibleFiles() {
        let model = WorkspaceModel()
        model.hiddenCategories = []
        let files = [makeFile("src/alpha.swift"), makeFile("src/beta.swift")]
        model.refresh(files: files)
        XCTAssertEqual(model.visibleFiles.count, 2)

        model.searchText = "ALPHA"
        model.refresh(files: files)
        XCTAssertEqual(model.visibleFiles.map(\.filename), ["src/alpha.swift"])
        XCTAssertEqual(model.orderedVisiblePaths, model.visibleFiles.map(\.filename))
    }

    /// The sidebar and the diff pane both drive `refresh` from the same five
    /// triggers, so every change arrives twice. The second call must be a
    /// no-op rather than a second tree build and a second publish.
    func testRepeatedRefreshWithUnchangedInputsIsANoOp() {
        let model = WorkspaceModel()
        model.hiddenCategories = []
        let files = [makeFile("src/a.swift"), makeFile("src/b.swift")]
        model.refresh(files: files)
        let firstTree = model.tree
        model.refresh(files: files)
        XCTAssertEqual(model.tree, firstTree)

        // …and a real change still lands.
        model.sortOption = .mostChanged
        model.refresh(files: [makeFile("src/a.swift", additions: 99, deletions: 0), makeFile("src/b.swift")])
        XCTAssertEqual(model.orderedVisiblePaths, ["src/a.swift", "src/b.swift"])
    }

    // MARK: Inline discussion index

    func testInlineThreadLookupMatchesTheEquivalentScan() {
        let model = WorkspaceModel()
        let threads = [
            thread("a.swift", line: 10, side: .right, rootId: 1),
            thread("a.swift", line: 10, side: .left, rootId: 2),
            thread("a.swift", line: 11, side: .right, rootId: 3),
            thread("b.swift", line: 10, side: .right, rootId: 4),
            thread("a.swift", line: nil, side: .right, rootId: 5),
        ]
        XCTAssertEqual(
            model.inlineThreads(in: threads, path: "a.swift", line: 10, side: .right).map(\.rootId), [1]
        )
        XCTAssertEqual(
            model.inlineThreads(in: threads, path: "a.swift", line: 10, side: .left).map(\.rootId), [2]
        )
        XCTAssertTrue(model.inlineThreads(in: threads, path: "a.swift", line: 99, side: .right).isEmpty)
        // An outdated thread has no line and anchors to no row.
        XCTAssertTrue(model.inlineThreads(in: threads, path: "a.swift", line: nil, side: .right).isEmpty)
    }

    /// GitHub's default side for a review comment is RIGHT. The split view
    /// always treated a missing side that way; the unified view used to drop
    /// the thread entirely, so the same thread appeared in one layout and
    /// not the other.
    func testThreadWithNoSideAnchorsToTheRightSide() {
        let model = WorkspaceModel()
        let threads = [thread("a.swift", line: 7, side: nil, rootId: 9)]
        XCTAssertEqual(model.inlineThreads(in: threads, path: "a.swift", line: 7, side: .right).map(\.rootId), [9])
        XCTAssertTrue(model.inlineThreads(in: threads, path: "a.swift", line: 7, side: .left).isEmpty)
    }

    func testInlineDraftLookupIsSideAndLineExact() {
        let model = WorkspaceModel()
        let drafts = [draft("a.swift", line: 3, side: .right), draft("a.swift", line: 3, side: .left)]
        XCTAssertEqual(model.inlineDrafts(in: drafts, path: "a.swift", line: 3, side: .right).count, 1)
        XCTAssertEqual(model.inlineDrafts(in: drafts, path: "a.swift", line: 3, side: .left).count, 1)
        XCTAssertTrue(model.inlineDrafts(in: drafts, path: "a.swift", line: 4, side: .right).isEmpty)
    }

    func testIndexRebuildsWhenTheSourceCollectionChanges() {
        let model = WorkspaceModel()
        let first = [thread("a.swift", line: 1, side: .right, rootId: 1)]
        XCTAssertEqual(model.inlineThreads(in: first, path: "a.swift", line: 1, side: .right).count, 1)
        let second = [thread("a.swift", line: 2, side: .right, rootId: 2)]
        XCTAssertTrue(model.inlineThreads(in: second, path: "a.swift", line: 1, side: .right).isEmpty)
        XCTAssertEqual(model.inlineThreads(in: second, path: "a.swift", line: 2, side: .right).count, 1)
    }

    // MARK: The file tree's comment badge

    func testBadgeCountsEveryThreadWhileResolutionStateIsUnknown() {
        let model = WorkspaceModel()
        let threads = [
            thread("a.swift", line: 1, side: .right, rootId: 1),
            thread("a.swift", line: nil, side: .right, rootId: 2),
        ]
        let badge = model.commentBadge(path: "a.swift", threads: threads, drafts: [])
        XCTAssertEqual(badge.threads, 2)
        XCTAssertFalse(badge.threadsAreUnresolvedOnly)
        XCTAssertEqual(badge.total, 2)
        XCTAssertEqual(badge.summary, "2 review threads")
    }

    func testBadgePrefersUnresolvedCountsOnceTheyArrive() {
        let model = WorkspaceModel()
        model.unresolvedCountsByPath = ["a.swift": 1]
        let threads = [
            thread("a.swift", line: 1, side: .right, rootId: 1),
            thread("a.swift", line: 2, side: .right, rootId: 2),
        ]
        let badge = model.commentBadge(path: "a.swift", threads: threads, drafts: [draft("a.swift", line: 5, side: .right)])
        XCTAssertEqual(badge.threads, 1)
        XCTAssertEqual(badge.drafts, 1)
        XCTAssertEqual(badge.total, 2)
        XCTAssertTrue(badge.threadsAreUnresolvedOnly)
        XCTAssertEqual(badge.summary, "1 unresolved thread, 1 draft comment")
    }

    func testBadgeIsEmptyForAFileWithNothingOnIt() {
        let model = WorkspaceModel()
        let badge = model.commentBadge(path: "untouched.swift", threads: [], drafts: [])
        XCTAssertEqual(badge.total, 0)
        XCTAssertEqual(badge.summary, "No comments on this file")
    }

    // MARK: Paired-row memo

    func testPairedRowsMatchTheDirectPairingAndInvalidateOnChange() {
        let model = WorkspaceModel()
        let parsed = DiffParser.parse(filename: "a.ts", patch: """
        @@ -1,3 +1,3 @@
         context
        -old line
        +new line
         trailing
        """)
        let lines = parsed.hunks[0].lines
        let expected = lines.pairedForSplitView()
        XCTAssertEqual(model.pairedRows(path: "a.ts", hunkIndex: 0, lines: lines), expected)
        // Served from the memo on the second call — same value, same key.
        XCTAssertEqual(model.pairedRows(path: "a.ts", hunkIndex: 0, lines: lines), expected)

        // A refetch that replaces the lines under the same key must not
        // serve the stale pairing.
        let other = DiffParser.parse(filename: "a.ts", patch: "@@ -1,1 +1,1 @@\n-x\n+y").hunks[0].lines
        XCTAssertEqual(model.pairedRows(path: "a.ts", hunkIndex: 0, lines: other), other.pairedForSplitView())
    }
}

/// What a multi-line draft sends to GitHub.
///
/// GitHub's review-comment shape is `line` for the last line plus
/// `start_line` for the first, and it rejects a `start_line` equal to `line`
/// — so a range that collapsed to one line has to become a single-line
/// comment rather than a range of one.
final class MultiLineDraftTests: XCTestCase {
    private func draft(line: Int, startLine: Int?) -> DraftComment {
        DraftComment(
            path: "a.swift", line: line, side: .right, body: "note", headSha: "sha",
            startLine: startLine, startSide: startLine == nil ? nil : .right
        )
    }

    func testASingleLineDraftHasNoRange() {
        let comment = draft(line: 42, startLine: nil)
        XCTAssertEqual(comment.lineRange, 42...42)
        XCTAssertFalse(comment.isMultiLine)
        XCTAssertEqual(comment.rangeDescription, "line 42")
    }

    func testARangeReadsAscendingAndDescribesItself() {
        let comment = draft(line: 47, startLine: 42)
        XCTAssertEqual(comment.lineRange, 42...47)
        XCTAssertTrue(comment.isMultiLine)
        XCTAssertEqual(comment.rangeDescription, "lines 42–47")
    }

    func testAStartEqualToTheEndCollapsesToASingleLine() {
        let comment = draft(line: 42, startLine: 42)
        XCTAssertEqual(comment.lineRange, 42...42)
        XCTAssertFalse(comment.isMultiLine, "GitHub rejects start_line == line")
    }

    /// A stored draft from before ranges existed must still decode.
    func testDraftsWrittenBeforeRangesExistedStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","path":"a.swift","line":7,"side":"RIGHT","body":"old","headSha":"sha"}
        """
        let decoded = try JSONDecoder().decode(DraftComment.self, from: Data(json.utf8))
        XCTAssertNil(decoded.startLine)
        XCTAssertEqual(decoded.lineRange, 7...7)
    }
}

/// What the opening screen is allowed to claim.
///
/// It said "the workspace opens as soon as the diff is in" while waiting for
/// all five requests, so a slow discussion endpoint — GitLab's, most often —
/// held the review behind a list stuck at "1 of 5".
final class PRLoadStageTests: XCTestCase {
    func testOnlyTheDiffGatesTheWorkspace() {
        XCTAssertTrue(PRLoadStage.pullRequest.gatesTheWorkspace)
        XCTAssertTrue(PRLoadStage.files.gatesTheWorkspace)
        XCTAssertFalse(PRLoadStage.comments.gatesTheWorkspace)
        XCTAssertFalse(PRLoadStage.reviews.gatesTheWorkspace)
        XCTAssertFalse(PRLoadStage.threads.gatesTheWorkspace)
    }

    /// A reviewer watching a GitLab instance load should see GitLab's words.
    func testStagesSpeakTheForgesVocabulary() {
        XCTAssertEqual(PRLoadStage.pullRequest.label(for: .gitlab), "Merge request")
        XCTAssertEqual(PRLoadStage.reviews.label(for: .gitlab), "Approvals")
        XCTAssertEqual(PRLoadStage.threads.label(for: .gitlab), "Discussions")
        XCTAssertEqual(PRLoadStage.files.label(for: .gitlab), "Changed files")

        XCTAssertEqual(PRLoadStage.pullRequest.label(for: .github), "Pull request")
        XCTAssertEqual(PRLoadStage.reviews.label(for: .github), "Reviews")
        XCTAssertEqual(PRLoadStage.threads.label(for: .github), "Review threads")
    }
}

/// What a keystroke in an inline comment costs the rest of the window.
@MainActor
final class ComposerPublishingTests: XCTestCase {
    /// Half-written comment text is read by exactly one view — the box it is
    /// being typed into. Every other view in the workspace observes this
    /// model, so publishing each character re-rendered the diff pane, the
    /// file tree, the toolbar and the filter bar for a change none of them
    /// could see.
    func testTypingAnInlineCommentRepublishesNothing() {
        let workspace = WorkspaceModel()
        var publishes = 0
        let subscription = workspace.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        for index in 0..<200 {
            workspace.setComposerText("a draft comment \(index)", path: "src/App.tsx", line: 42, side: .right)
        }

        XCTAssertEqual(publishes, 0, "typing must not re-render the workspace")
        XCTAssertEqual(
            workspace.composerText(path: "src/App.tsx", line: 42, side: .right),
            "a draft comment 199",
            "and the text must still be there when the row is recycled"
        )
    }
}
