import XCTest

final class DiffParserTests: XCTestCase {
    let samplePatch = """
    @@ -20,6 +20,8 @@ export function canRemoveMember(member: Member): boolean {
       return member.role === "ADMIN"
     }

    -export function canRemoveMember(member: Member): boolean {
    -  return member.role === "ADMIN"
    +export function canRemoveMember(member: Member): boolean {
    +  return member.role === "ADMIN"
    +}
    +
    +export function canInviteMembers(member: Member): boolean {
    +  return member.role === "ADMIN"
     }
    """

    func testParsesHunkHeader() {
        let parsed = DiffParser.parse(filename: "a.ts", patch: samplePatch)
        XCTAssertEqual(parsed.hunks.count, 1)
        let hunk = parsed.hunks[0]
        XCTAssertEqual(hunk.oldStart, 20)
        XCTAssertEqual(hunk.oldCount, 6)
        XCTAssertEqual(hunk.newStart, 20)
        XCTAssertEqual(hunk.newCount, 8)
    }

    func testLineKindsAndNumbering() {
        let parsed = DiffParser.parse(filename: "a.ts", patch: samplePatch)
        let lines = parsed.hunks[0].lines

        // 3 leading context lines + the blank line before the closing brace = 4.
        XCTAssertEqual(lines.filter { $0.kind == .context }.count, 4)
        XCTAssertEqual(lines.filter { $0.kind == .addition }.count, 6)
        XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, 2)

        let firstContext = lines.first { $0.kind == .context }
        XCTAssertEqual(firstContext?.oldLineNumber, 20)
        XCTAssertEqual(firstContext?.newLineNumber, 20)

        let firstDeletion = lines.first { $0.kind == .deletion }
        XCTAssertEqual(firstDeletion?.oldLineNumber, 23)
        XCTAssertNil(firstDeletion?.newLineNumber)

        let firstAddition = lines.first { $0.kind == .addition }
        XCTAssertEqual(firstAddition?.newLineNumber, 23)
        XCTAssertNil(firstAddition?.oldLineNumber)
    }

    func testEmptyPatchProducesNoHunks() {
        let parsed = DiffParser.parse(filename: "a.ts", patch: nil)
        XCTAssertTrue(parsed.hunks.isEmpty)
    }

    func testGapSizeBeforeFirstHunk() {
        let parsed = DiffParser.parse(filename: "a.ts", patch: samplePatch)
        // First hunk starts at new line 20, so 19 lines are hidden above it.
        XCTAssertEqual(DiffParser.gapSize(beforeHunkIndex: 0, hunks: parsed.hunks), 19)
    }

    func testGapSizeBetweenHunks() {
        let twoHunkPatch = """
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        @@ -10,3 +10,3 @@
         x
        -y
        +Y
         z
        """
        let parsed = DiffParser.parse(filename: "a.ts", patch: twoHunkPatch)
        XCTAssertEqual(parsed.hunks.count, 2)
        // First hunk covers new lines 1-3; second hunk starts at new line 10 -> 6 hidden lines (4,5,...,9).
        XCTAssertEqual(DiffParser.gapSize(beforeHunkIndex: 1, hunks: parsed.hunks), 6)
    }

    func testGapLinesReconstructsContextWithOffset() {
        let twoHunkPatch = """
        @@ -1,2 +1,3 @@
         a
        +INSERTED
         b
        @@ -10,2 +11,2 @@
         x
         y
        """
        let parsed = DiffParser.parse(filename: "a.ts", patch: twoHunkPatch)
        // One net addition in hunk 0 means old/new are offset by 1 afterwards.
        let fullLines = (1...20).map { "line\($0)" }
        let gap = DiffParser.gapLines(beforeHunkIndex: 1, hunks: parsed.hunks, fullLines: fullLines)
        XCTAssertEqual(gap.first?.newLineNumber, 4)
        XCTAssertEqual(gap.first?.oldLineNumber, 3)
        XCTAssertEqual(gap.last?.newLineNumber, 10)
        XCTAssertEqual(gap.last?.oldLineNumber, 9)
        XCTAssertEqual(gap.first?.text, "line4")
    }

    func testSplitViewPairsReplaceRowsBeforeLoneAdditions() {
        let parsed = DiffParser.parse(filename: "a.ts", patch: samplePatch)
        let rows = parsed.hunks[0].lines.pairedForSplitView()
        // 2 deletions pair with the first 2 of 6 additions; the remaining 4 additions are lone rows.
        let replaceRows = rows.filter { $0.left != nil && $0.right != nil && $0.left?.kind == .deletion }
        let loneAdditionRows = rows.filter { $0.left == nil && $0.right?.kind == .addition }
        XCTAssertEqual(replaceRows.count, 2)
        XCTAssertEqual(loneAdditionRows.count, 4)
    }
}
