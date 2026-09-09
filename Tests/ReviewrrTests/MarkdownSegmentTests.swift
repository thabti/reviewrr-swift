import XCTest

/// Comment-body parsing, driven by the shape review bots actually post.
final class MarkdownSegmentTests: XCTestCase {
    // MARK: - Tables

    func testParsesASimpleTable() {
        let source = """
        | Severity | Count |
        |---|---|
        | ⚠️ Warning | 2 |
        | ℹ️ Info | 2 |
        """
        let segments = MarkdownSegmenter.segments(from: source)
        guard case .table(let table)? = segments.first else {
            return XCTFail("expected a table, got \(segments)")
        }
        XCTAssertEqual(table.headers, ["Severity", "Count"])
        XCTAssertEqual(table.rows, [["⚠️ Warning", "2"], ["ℹ️ Info", "2"]])
        XCTAssertEqual(table.alignments, [.leading, .leading])
    }

    func testReadsAlignmentFromTheDelimiterRow() {
        let source = """
        | Left | Middle | Right |
        | :--- | :----: | ----: |
        | a | b | c |
        """
        guard case .table(let table)? = MarkdownSegmenter.segments(from: source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
    }

    /// The outer pipes are optional in GFM, and a bot may or may not use
    /// them. Both forms have to produce the same table.
    func testOuterPipesAreOptional() {
        let withPipes = MarkdownSegmenter.segments(from: "| a | b |\n|---|---|\n| 1 | 2 |")
        let without = MarkdownSegmenter.segments(from: "a | b\n---|---\n1 | 2")
        XCTAssertEqual(withPipes, without)
    }

    /// A line with pipes is not a table without a delimiter row under it —
    /// otherwise prose mentioning `a | b` would become a one-row grid.
    func testPipesWithoutADelimiterRowStayProse() {
        let source = "Use the pipe operator: value | transform | render"
        let segments = MarkdownSegmenter.segments(from: source)
        XCTAssertEqual(segments, [.markdown(source)])
    }

    func testDelimiterRowMustMatchTheHeadersColumnCount() {
        // Three headers, two delimiters — not a table.
        let source = "| a | b | c |\n|---|---|\n| 1 | 2 | 3 |"
        XCTAssertEqual(MarkdownSegmenter.segments(from: source), [.markdown(source)])
    }

    /// GFM pads short rows and truncates long ones rather than rejecting the
    /// table, so a bot that miscounts a column still renders something.
    func testShortAndLongRowsAreNormalizedToTheHeaderWidth() {
        let source = """
        | a | b | c |
        |---|---|---|
        | 1 |
        | 1 | 2 | 3 | 4 |
        """
        guard case .table(let table)? = MarkdownSegmenter.segments(from: source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.rows[0], ["1", "", ""])
        XCTAssertEqual(table.rows[1], ["1", "2", "3"])
    }

    func testEscapedPipeStaysInsideItsCell() {
        let source = "| expr | meaning |\n|---|---|\n| a \\| b | either |"
        guard case .table(let table)? = MarkdownSegmenter.segments(from: source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.rows, [["a | b", "either"]])
    }

    func testTableEndsAtABlankLineAndProseResumes() {
        let source = """
        | a | b |
        |---|---|
        | 1 | 2 |

        Text after the table.
        """
        let segments = MarkdownSegmenter.segments(from: source)
        XCTAssertEqual(segments.count, 2)
        guard case .table = segments[0] else { return XCTFail("expected a table first") }
        guard case .markdown(let trailing) = segments[1] else { return XCTFail("expected prose second") }
        XCTAssertTrue(trailing.contains("Text after the table."))
    }

    // MARK: - Fenced code

    /// A table inside a fence is code. This is why fences are detected
    /// first — otherwise a comment demonstrating markdown would have its
    /// example silently rendered as a real table.
    func testATableInsideAFenceStaysCode() {
        let source = """
        ```markdown
        | a | b |
        |---|---|
        ```
        """
        let segments = MarkdownSegmenter.segments(from: source)
        XCTAssertEqual(segments.count, 1)
        guard case .codeBlock(let language, let code) = segments[0] else {
            return XCTFail("expected a code block, got \(segments)")
        }
        XCTAssertEqual(language, "markdown")
        XCTAssertTrue(code.contains("| a | b |"))
    }

    func testTildeFencesAndUnterminatedFences() {
        guard case .codeBlock(_, let tilde)? = MarkdownSegmenter.segments(from: "~~~\nx = 1\n~~~").first else {
            return XCTFail("expected a tilde fence")
        }
        XCTAssertEqual(tilde, "x = 1")

        // An unterminated fence runs to the end, as every markdown
        // implementation does, rather than swallowing the parse.
        guard case .codeBlock(_, let open)? = MarkdownSegmenter.segments(from: "```\nstill code").first else {
            return XCTFail("expected an unterminated fence to parse")
        }
        XCTAssertEqual(open, "still code")
    }

    // MARK: - Inline HTML

    func testStripsTagsButKeepsTheirText() {
        let stripped = MarkdownSegmenter.stripInlineHTML("<sub>Automated by Claude AI · Magento 2 Architect Review</sub>")
        XCTAssertEqual(stripped, "Automated by Claude AI · Magento 2 Architect Review")
    }

    func testBreakTagsBecomeRealLineBreaks() {
        // Dropping these would join two lines a bot deliberately separated.
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML("one<br>two"), "one\ntwo")
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML("one<br/>two"), "one\ntwo")
    }

    func testStripsOpeningTagsThatCarryAttributes() {
        let stripped = MarkdownSegmenter.stripInlineHTML(#"<a href="https://example.com">link</a>"#)
        XCTAssertEqual(stripped, "link")
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML("<details open><summary>More</summary>body</details>"), "Morebody")
    }

    func testStripsHTMLComments() {
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML("visible<!-- hidden -->text"), "visibletext")
    }

    /// An unterminated tag must not eat the rest of the comment.
    func testUnterminatedTagLeavesTheRemainderAlone() {
        let source = "before <a href=\"unclosed"
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML(source), source)
    }

    func testLeavesOrdinaryAngleBracketsAlone() {
        // Not HTML: comparisons and generics appear in review comments
        // constantly, and mangling them would corrupt the text.
        let source = "if (a < b && c > d) — and Array<String>"
        XCTAssertEqual(MarkdownSegmenter.stripInlineHTML(source), source)
    }

    // MARK: - Suggested changes

    /// GitHub's suggested-change syntax. This is the one code block in a
    /// review that is a proposal rather than an illustration.
    func testPlainSuggestionFenceBecomesASuggestion() {
        let source = """
        ```suggestion
        const verticalConfig = useMemo(
          () => getVertical(activeVertical) ?? getVertical("ecommerce"),
          [activeVertical],
        );
        ```
        """
        guard case .suggestion(let change)? = MarkdownSegmenter.segments(from: source).first else {
            return XCTFail("expected a suggestion, got \(MarkdownSegmenter.segments(from: source))")
        }
        XCTAssertTrue(change.code.contains("useMemo("))
        XCTAssertNil(change.replacedLineCount, "a plain fence carries no range")
        // Indentation is part of the proposal and must survive verbatim.
        XCTAssertTrue(change.code.contains("\n  () => getVertical"))
    }

    /// GitLab's variant names how many lines around the anchor it replaces.
    func testGitLabSuggestionRangeIsParsed() {
        guard case .suggestion(let change)? = MarkdownSegmenter
            .segments(from: "```suggestion:-2+3\nreplacement\n```").first
        else { return XCTFail("expected a suggestion") }
        XCTAssertEqual(change.linesAbove, 2)
        XCTAssertEqual(change.linesBelow, 3)
        XCTAssertEqual(change.replacedLineCount, 6)
    }

    func testSuggestionWithZeroOffsetsReplacesOneLine() {
        guard case .suggestion(let change)? = MarkdownSegmenter
            .segments(from: "```suggestion:-0+0\nx\n```").first
        else { return XCTFail("expected a suggestion") }
        XCTAssertEqual(change.replacedLineCount, 1)
    }

    /// A language that merely begins with the word is a normal code block —
    /// otherwise a fence tagged `suggestions.json` would be misread.
    func testOnlyTheSuggestionKeywordCounts() {
        for info in ["suggestions", "suggestion-box", "swift", "php"] {
            let segments = MarkdownSegmenter.segments(from: "```\(info)\ncode\n```")
            guard case .codeBlock = segments.first else {
                return XCTFail("\(info) should be an ordinary code block, got \(segments)")
            }
        }
    }

    /// A malformed range must not hide the proposal — the code is the part
    /// the reviewer needs.
    func testMalformedRangeStillYieldsTheSuggestion() {
        guard case .suggestion(let change)? = MarkdownSegmenter
            .segments(from: "```suggestion:garbage\nx\n```").first
        else { return XCTFail("expected a suggestion despite the bad range") }
        XCTAssertEqual(change.code, "x")
        XCTAssertNil(change.replacedLineCount)
    }

    // MARK: - Emoji shortcodes

    func testReplacesShortcodesBotsActuallyUse() {
        XCTAssertEqual(EmojiShortcodes.replace(in: ":stop_sign: Logic Error"), "🛑 Logic Error")
        XCTAssertEqual(EmojiShortcodes.replace(in: ":warning:"), "⚠️")
        XCTAssertEqual(EmojiShortcodes.replace(in: ":white_check_mark: passed"), "✅ passed")
        XCTAssertEqual(EmojiShortcodes.replace(in: "LGTM :+1:"), "LGTM 👍")
    }

    /// An unknown shortcode is left as written — the same thing GitHub does
    /// with one it does not recognize.
    func testUnknownShortcodesAreLeftAlone() {
        XCTAssertEqual(
            EmojiShortcodes.replace(in: ":not_a_real_emoji: text"),
            ":not_a_real_emoji: text"
        )
    }

    /// A colon that is not a shortcode must not break the ones after it.
    func testTimestampsAndRatiosSurvive() {
        XCTAssertEqual(EmojiShortcodes.replace(in: "at 10:30 see :warning:"), "at 10:30 see ⚠️")
        XCTAssertEqual(EmojiShortcodes.replace(in: "ratio 3:1"), "ratio 3:1")
        XCTAssertEqual(EmojiShortcodes.replace(in: "https://example.com"), "https://example.com")
    }

    /// Inside a code span the text is code, not an emoji.
    func testCodeSpansAreNotTouched() {
        XCTAssertEqual(
            EmojiShortcodes.replace(in: "use `array[:warning:]` here"),
            "use `array[:warning:]` here"
        )
        // …but a shortcode after the span still resolves.
        XCTAssertEqual(
            EmojiShortcodes.replace(in: "`:key:` then :warning:"),
            "`:key:` then ⚠️"
        )
    }

    func testNoColonsIsReturnedUnchanged() {
        let source = "Plain sentence with no shortcodes."
        XCTAssertEqual(EmojiShortcodes.replace(in: source), source)
    }

    /// The bot comment from the inline-comment screenshot, end to end.
    func testAmazonQStyleInlineCommentWithSuggestion() {
        let source = """
        :stop_sign: **Logic Error**: Fallback logic executed inside conditional breaks memoization.

        Lines 23-26 call `getVertical("ecommerce")` inside the conditional.

        ```suggestion
        export function ShellNavigator() {
          const activeVertical = useShellStore((state) => state.activeVertical);
        }
        ```
        """
        let segments = MarkdownSegmenter.segments(from: source)

        guard case .markdown(let prose) = segments[0] else {
            return XCTFail("expected prose first, got \(segments)")
        }
        XCTAssertEqual(
            EmojiShortcodes.replace(in: prose).prefix(1),
            "🛑",
            "the shortcode is what made this comment start with a colon"
        )
        // The inline code span in the prose is untouched by emoji handling.
        XCTAssertTrue(EmojiShortcodes.replace(in: prose).contains("`getVertical(\"ecommerce\")`"))

        guard case .suggestion(let change) = segments[1] else {
            return XCTFail("expected a suggestion second, got \(segments)")
        }
        XCTAssertTrue(change.code.contains("export function ShellNavigator()"))
    }

    // MARK: - Hard breaks

    /// Markdown joins consecutive lines into a paragraph; GitLab and GitHub
    /// render a newline in a comment as a line break. Two findings written
    /// on separate lines must not arrive as one run-on sentence.
    func testConsecutiveProseLinesGetHardBreaks() {
        let source = "First line\nSecond line"
        XCTAssertEqual(MarkdownSegmenter.applyHardBreaks(source), "First line  \nSecond line")
    }

    func testBlankSeparatedParagraphsAreLeftAlone() {
        let source = "First paragraph\n\nSecond paragraph"
        XCTAssertEqual(MarkdownSegmenter.applyHardBreaks(source), source)
    }

    /// Block constructs keep markdown's own meaning — appending two spaces
    /// inside a list would change its structure rather than its wrapping.
    func testBlockConstructsAreNotGivenHardBreaks() {
        for source in [
            "- one\n- two",
            "1. one\n2. two",
            "## Heading\nText under it",
            "> quoted\n> more",
            "| a | b |\n|---|---|",
            "Text\n    indented code",
        ] {
            XCTAssertEqual(MarkdownSegmenter.applyHardBreaks(source), source, source)
        }
    }

    func testDoesNotDoubleUpAnExistingHardBreak() {
        XCTAssertEqual(MarkdownSegmenter.applyHardBreaks("one  \ntwo"), "one  \ntwo")
        XCTAssertEqual(MarkdownSegmenter.applyHardBreaks("one\\\ntwo"), "one\\\ntwo")
    }

    /// A dash that is not a list marker is prose, and a sentence continuing
    /// under it still needs its break.
    func testDashWithoutASpaceIsProseNotAList() {
        XCTAssertFalse(MarkdownSegmenter.startsBlock("-42 degrees"))
        XCTAssertTrue(MarkdownSegmenter.startsBlock("- a list item"))
        XCTAssertTrue(MarkdownSegmenter.startsBlock("---"))
        XCTAssertFalse(MarkdownSegmenter.startsBlock("1.5 seconds"))
        XCTAssertTrue(MarkdownSegmenter.startsBlock("1. first"))
    }

    // MARK: - The real thing

    /// The bot comment that prompted this: a heading, a bold line, a table,
    /// a list of findings with inline code, a rule, and an HTML footer.
    func testParsesAWholeReviewBotComment() {
        let source = """
        ## 🤖 Claude AI Code Review

        **4 finding(s)** across changed files

        | Severity | Count |
        |---|---|
        | ⚠️ Warning | 2 |
        | ℹ️ Info | 2 |

        - ⚠️ **WARNING** `src/BuyAgain/Model/BuyAgainItemsProvider.php:311` — mapVerticalSkusToProductIds() is called twice per request.
        - ℹ️ **INFO** `src/BuyAgain/Test/Unit/Model/BuyAgainItemsProviderTest.php:320` — asserts duplicate product IDs.

        ---
        <sub>Automated by Claude AI · Magento 2 Architect Review</sub>
        """

        let segments = MarkdownSegmenter.segments(from: MarkdownSegmenter.stripInlineHTML(source))

        // Exactly one table, found in the middle of the body.
        let tables = segments.compactMap { segment -> MarkdownTable? in
            if case .table(let table) = segment { return table }
            return nil
        }
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].headers, ["Severity", "Count"])
        XCTAssertEqual(tables[0].rows.count, 2)

        // The prose around it survives, and the footer's tags are gone.
        let prose = segments.compactMap { segment -> String? in
            if case .markdown(let text) = segment { return text }
            return nil
        }.joined(separator: "\n")

        XCTAssertTrue(prose.contains("## 🤖 Claude AI Code Review"))
        XCTAssertTrue(prose.contains("**4 finding(s)**"))
        XCTAssertTrue(prose.contains("BuyAgainItemsProvider.php:311"))
        XCTAssertTrue(prose.contains("Automated by Claude AI"))
        XCTAssertFalse(prose.contains("<sub>"), "HTML tags must not reach the reader")
        XCTAssertFalse(prose.contains("</sub>"))
    }

    /// Nothing in a body without special constructs should be disturbed.
    func testPlainCommentIsOneSegment() {
        let source = "Looks good to me — one nit on line 12, otherwise ship it."
        XCTAssertEqual(MarkdownSegmenter.segments(from: source), [.markdown(source)])
    }

    func testEmptyAndWhitespaceOnlyBodiesProduceNoSegments() {
        XCTAssertTrue(MarkdownSegmenter.segments(from: "").isEmpty)
        XCTAssertTrue(MarkdownSegmenter.segments(from: "   \n\n  ").isEmpty)
    }
}
