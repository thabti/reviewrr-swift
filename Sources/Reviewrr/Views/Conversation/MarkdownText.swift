import SwiftUI

/// Renders a comment body.
///
/// Foundation parses block structure, but SwiftUI `Text` only draws inline
/// attributes — so each block is kept separate to retain its layout in a
/// narrow rail. Two constructs Foundation does not handle are split out
/// first by `MarkdownSegmenter` and drawn here:
///
/// - **Tables.** `AttributedString(markdown:)` has no GFM table support at
///   all; it renders the rows as paragraphs, which turned a review bot's
///   severity table into a wall of pipe characters.
/// - **Fenced code.** Pulled out so a table *inside* a fence is code rather
///   than a table, and so the code block gets a scroll view of its own
///   instead of wrapping.
///
/// Inline HTML is stripped rather than shown: bot comments carry `<sub>`
/// footers, `<br>` inside table cells and `<details>` sections, and
/// Foundation prints those tags verbatim.
struct MarkdownText: View {
    /// Jira, when the team runs one — a key in a description or a comment
    /// becomes a link. Empty and disabled by default, so this costs nothing
    /// until it is configured.
    @Environment(\.issueTracker) private var tracker
    let text: String
    /// The file the comment is anchored to, when there is one. A suggestion
    /// block carries no language of its own — the fence says "suggestion" —
    /// so the path is the only thing that can say how to colour it.
    var languageHint: String?

    init(text: String, languageHint: String? = nil) {
        self.text = text
        self.languageHint = languageHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                switch segment {
                case .markdown(let body):
                    MarkdownBlocks(text: body)
                case .table(let table):
                    MarkdownTableView(table: table)
                case .codeBlock(let language, let code):
                    MarkdownCodeBlock(language: language, code: code)
                case .suggestion(let change):
                    SuggestedChangeView(change: change, language: languageHint)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Shortcodes are replaced before segmentation, and only in prose:
    /// `:stop_sign:` in a comment is an emoji, but the same text inside a
    /// fenced block is code and must survive untouched.
    private var segments: [MarkdownSegment] {
        MarkdownSegmenter.segments(from: MarkdownSegmenter.stripInlineHTML(text))
            .map { segment in
                switch segment {
                case .markdown(let body):
                    return .markdown(prose(body))
                case .table(let table):
                    var replaced = table
                    replaced.headers = table.headers.map(prose)
                    replaced.rows = table.rows.map { $0.map(prose) }
                    return .table(replaced)
                case .codeBlock, .suggestion:
                    // Code is code: neither a shortcode nor an issue key
                    // means anything inside a fenced block.
                    return segment
                }
            }
    }

    /// Every rewrite that applies to prose but not to code, in one place:
    /// emoji shortcodes, then issue keys into links.
    private func prose(_ text: String) -> String {
        IssueKeyLinker.linkify(EmojiShortcodes.replace(in: text), settings: tracker)
    }
}

// MARK: - Suggested changes

/// A ```` ```suggestion ```` block.
///
/// Presented as a proposal rather than as an illustration: every other code
/// block in a comment shows what the author is talking *about*, and this one
/// is what they want the file to say. It gets a named header, a green edge
/// borrowed from the diff's addition colour, syntax highlighting, and a copy
/// button — because applying it is the reader's next move.
///
/// No "Apply" button. Committing a suggestion is a write to the branch, and
/// a one-click commit from a review pane is not something to offer behind an
/// approximation of GitHub's semantics — copying the text is honest and
/// costs the reviewer one paste.
private struct SuggestedChangeView: View {
    let change: SuggestedChange
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            code
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                .strokeBorder(Theme.addedText.opacity(0.35))
        )
        .overlay(alignment: .leading) {
            // The diff's own addition colour, so a suggestion reads as
            // "this becomes the file" at a glance.
            Rectangle()
                .fill(Theme.addedText.opacity(0.8))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Label("Suggested change", systemImage: "plus.forwardslash.minus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.addedText)

            if let count = change.replacedLineCount {
                Text("replaces \(count) line\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.code, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Theme.addedText : .secondary)
            .help("Copy the suggested code")
            .accessibilityLabel(copied ? "Copied" : "Copy the suggested code")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 5)
        .padding(.leading, 3)
        .background(Theme.addedBackground.opacity(0.5))
    }

    private var code: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Line by line, because the highlighter works per line — and
                // because a suggestion's indentation is part of the proposal,
                // so nothing here trims leading whitespace.
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(SyntaxHighlighter.highlight(line, language: language ?? "plain"))
                        .font(Theme.monoFontSmall)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .padding(.leading, 3)
        }
    }

    /// An empty suggestion is a deletion — the proposal is that these lines
    /// go away — so it renders one placeholder row rather than nothing at
    /// all, which would look like a broken block.
    private var lines: [String] {
        let body = change.code.components(separatedBy: "\n")
        let trimmed = body.count > 1 && (body.last?.isEmpty ?? false) ? body.dropLast() : body[...]
        return trimmed.isEmpty || (trimmed.count == 1 && trimmed.first?.isEmpty == true)
            ? ["(delete these lines)"]
            : Array(trimmed)
    }
}

// MARK: - Tables

/// A GFM table as an actual grid.
///
/// `Grid` rather than a `VStack` of `HStack`s: column widths have to be
/// decided across every row, and a severity column sized per row would
/// stagger down the table. Horizontally scrollable because a comment rail
/// is narrow and a bot's table is not — truncating a cell would lose the
/// finding it names.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        cell(header, alignment: alignment(index), isHeader: true)
                    }
                }
                .background(Theme.codeBackground)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            cell(value, alignment: alignment(index), isHeader: false)
                        }
                    }
                    // Zebra striping, kept very faint: it helps the eye track
                    // a row across columns without turning the table into
                    // the loudest thing in a comment.
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Theme.controlFill.opacity(0.5))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                    .strokeBorder(Theme.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            .padding(.vertical, 2)
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private func alignment(_ index: Int) -> MarkdownTable.Alignment {
        index < table.alignments.count ? table.alignments[index] : .leading
    }

    private func cell(_ value: String, alignment: MarkdownTable.Alignment, isHeader: Bool) -> some View {
        // Cells carry inline markdown — `**2**`, `` `path.php` `` — so each
        // is parsed inline-only. Block parsing here would turn a cell
        // beginning with "-" into a list.
        Text(Self.inline(value))
            .font(isHeader ? .callout.weight(.semibold) : .callout)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .multilineTextAlignment(textAlignment(alignment))
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> SwiftUI.Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    static func inline(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }

    /// One spoken sentence per row rather than a cell-by-cell crawl, which
    /// is what VoiceOver does with a grid of separate labels.
    private var accessibilityDescription: String {
        let header = table.headers.joined(separator: ", ")
        let body = table.rows.map { row in
            zip(table.headers, row).map { "\($0): \($1)" }.joined(separator: ", ")
        }
        return ([header] + body).joined(separator: ". ")
    }
}

// MARK: - Code

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(code.trimmingCharacters(in: .newlines).components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        // The app already has a highlighter for the diff;
                        // a fenced block in a comment is the same kind of
                        // content and reads far better coloured.
                        Text(SyntaxHighlighter.highlight(line, language: language ?? "plain"))
                            .font(Theme.monoFontSmall)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.Space.s)
            }
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
        }
    }
}

// MARK: - Everything Foundation handles

/// The original block renderer: headings, lists, quotes, thematic breaks and
/// inline emphasis, via `AttributedString`'s presentation intents.
private struct MarkdownBlocks: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.blocks(from: text)) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = block.marker {
                        Text(marker)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                    }
                    content(block)
                }
                .padding(.leading, CGFloat(block.depth) * 16)
                .padding(.leading, block.quoted ? 12 : 0)
                .overlay(alignment: .leading) {
                    if block.quoted {
                        Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ block: Block) -> some View {
        if block.divider {
            Divider()
        } else if block.code {
            ScrollView(.horizontal) {
                Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                    .font(Theme.monoFontSmall)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
        } else if let level = block.heading {
            Text(block.text)
                // A comment is not a document: an `h1` bot heading rendered
                // at `.title` size shouted louder than the pull request's
                // own title. The scale is compressed and starts lower.
                .font(level <= 1 ? .title3 : level == 2 ? .headline : .subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(block.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        var heading: Int?
        var marker: String?
        var depth = 0
        var quoted = false
        var code = false
        var divider = false
    }

    private static func blocks(from source: String) -> [Block] {
        // `.full` is the default and does block parsing, which is what the
        // presentation intents below depend on. It also joins consecutive
        // lines into one paragraph — so the newlines a comment author meant
        // are converted to markdown hard breaks first (see
        // `MarkdownSegmenter.applyHardBreaks`).
        //
        // `returnPartiallyParsedIfPossible` so a malformed construct costs
        // the reader that construct rather than the whole comment.
        guard let parsed = try? AttributedString(
            markdown: MarkdownSegmenter.applyHardBreaks(source),
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return [Block(id: 0, text: AttributedString(source))]
        }
        var result: [Block] = []
        var markedItems: Set<Int> = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var fragment = AttributedString(parsed[run.range])
            // Layout is handled here; preserve the inline emphasis, code and link attributes.
            fragment.presentationIntent = nil
            if result.last?.id == id {
                result[result.count - 1].text.append(fragment)
                continue
            }
            var block = Block(id: id, text: fragment)
            var listCount = 0
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            for component in components {
                switch component.kind {
                case .header(let level): block.heading = level
                case .codeBlock: block.code = true
                case .thematicBreak: block.divider = true
                case .blockQuote: block.quoted = true
                case .listItem(let ordinal):
                    if item == nil { item = (component.identity, ordinal) }
                case .orderedList:
                    if listCount == 0 { ordered = true }
                    listCount += 1
                case .unorderedList:
                    listCount += 1
                default: break
                }
            }
            block.depth = max(0, listCount - 1)
            if let item {
                block.marker = markedItems.insert(item.id).inserted
                    ? (ordered ? "\(item.ordinal)." : "•") : ""
            }
            result.append(block)
        }
        return result
    }
}
