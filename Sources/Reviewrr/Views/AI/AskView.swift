import SwiftUI

/// The Ask tab: a PR-scoped conversation with streaming replies, starter
/// questions, `path:line` citations turned into jump links, and an explicit
/// "turn this into a draft comment" action per citation. Reviewrr never
/// creates the draft itself — it calls back into the workspace, which owns
/// the current head SHA and diff anchor.
struct AskTabView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: AIModel
    var onNavigate: (String, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if model.messages.isEmpty {
                            emptyState
                        }
                        ForEach(model.messages) { message in
                            Group {
                                if message.role == .system {
                                    // Reviewrr's own note in the transcript —
                                    // the revision moved, for instance. Styled
                                    // as neither a question nor an answer so it
                                    // cannot be mistaken for either.
                                    TranscriptNoticeRow(text: message.content)
                                } else {
                                    AskBubble(message: message, onNavigate: onNavigate)
                                }
                            }
                            .id(message.id)
                            .motionTransition(.reviewrrRow)
                        }
                        if let error = model.askError {
                            askErrorBanner(error)
                        }
                    }
                    // No inset here: an answer is the widest thing in a
                    // 400pt rail and it was being squeezed twice, by this
                    // padding and by its own card. Each row now sets its own
                    // insets, so an answer runs the full width of the panel
                    // and a question stays a contained bubble.
                    .padding(.vertical, Theme.Space.s)
                    // Animating on the array itself fired on every streamed
                    // chunk — the message's content changes dozens of times
                    // a second, so a long answer spring-animated its own
                    // height continuously and never settled. A message
                    // arriving or leaving is the discrete event worth
                    // animating; the text growing inside one is not.
                    .motion(Motion.smooth, value: model.messages.count)
                }
                .safeAreaPadding(.bottom, 12)
                .frame(minHeight: 0, maxHeight: .infinity)
                // Streaming grows the last message's content chunk by
                // chunk, not just on a new message arriving — following it
                // as it grows is what keeps a long reply from scrolling
                // out from under the reviewer mid-stream.
                .onChange(of: model.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.messages.last?.content) { _, _ in scrollToBottom(proxy) }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                AIAskComposerView(model: model, composer: model.askComposer)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(Theme.barMaterial)
        }
    }

    /// A configuration-shaped failure (no key, no provider) gets a direct
    /// path to fix it, not just an apology — every other failure still
    /// surfaces GitHub/provider's own message, just without a link that
    /// wouldn't help.
    @ViewBuilder
    private func askErrorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            if message.localizedCaseInsensitiveContains("API key") || message.localizedCaseInsensitiveContains("Settings") {
                Button { openSettings(.ai) } label: {
                    Label("Open AI Settings", systemImage: "gearshape")
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last else { return }
        // `withAnimation` doesn't consult Reduce Motion on its own — unlike
        // the `.motion` view modifier, a scroll-position change has no
        // Equatable value to hang that check on, so it's done by hand here.
        //
        // A streaming reply is the other unanimated case: the scroll target
        // moves with every chunk, and a spring per chunk means the viewport
        // is permanently in flight. Follow the growing text directly and
        // keep the animation for the discrete jump to a new message.
        if reduceMotion || last.isStreaming {
            proxy.scrollTo(last.id, anchor: .bottom)
        } else {
            withAnimation(Motion.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            EmptyStateView(
                systemImage: "sparkles",
                title: "Ask about this PR",
                message: "Answers cite `path:line` so you can jump straight to the code."
            )
            .frame(maxWidth: .infinity)

            if !model.starterQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.starterQuestions, id: \.self) { suggestion in
                        Button {
                            model.askComposer.text = suggestion
                            model.askComposer.selection = NSRange(location: suggestion.utf16.count, length: 0)
                            model.askComposer.focusRequest += 1
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Text(suggestion)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.reviewrrSecondary)
                        .help("Ask: \(suggestion)")
                        .accessibilityLabel("Ask: \(suggestion)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct AskBubble: View {
    let message: ChatMessage
    var onNavigate: (String, Int) -> Void

    private var citations: [Citations.Citation] {
        guard message.role == .assistant else { return [] }
        // One entry per distinct path:line — a citation repeated in prose
        // shouldn't produce duplicate jump links.
        var seen = Set<String>()
        return Citations.extract(from: message.content).filter { seen.insert("\($0.path):\($0.startLine)").inserted }
    }

    /// Role reads from the icon and label together, never from bubble
    /// color alone — a user with any color-vision difference still knows
    /// who said what.
    private var roleLabel: String { message.role == .user ? "You" : "AI" }
    private var roleSymbol: String { message.role == .user ? "person.fill" : "sparkles" }

    var body: some View {
        if message.role == .user {
            question
        } else {
            answer
        }
    }

    /// The reviewer's own question: a contained bubble, right-aligned and
    /// held short of the full width, so a transcript still reads as a
    /// dialogue rather than as one undifferentiated column of text.
    private var question: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label(roleLabel, systemImage: roleSymbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let files = message.taggedFiles, !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tagged PR files").font(.caption2).foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { path in
                        Label(path, systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            MarkdownText(text: message.content)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Theme.accent.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                )
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The answer runs the full width of the rail.
    ///
    /// It used to sit in a rounded card inside a padded stack — two insets
    /// deep, so the longest text in the app got the narrowest measure, and a
    /// fenced code block wrapped twice as often as it needed to. Identity
    /// comes from a purple edge and the tinted field behind it instead of
    /// from a box: same signal, none of the width.
    private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(roleLabel, systemImage: roleSymbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AIVisualStyle.accent)

            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 6) {
                        ActivityDot(color: AIVisualStyle.accent)
                        Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    // The same renderer every GitHub comment goes through.
                    // An answer about code is the message most likely to
                    // contain a fence, a bullet list or a bold identifier,
                    // and it was the only one in the app showing them raw.
                    // Formatting is not identity: the purple card, the
                    // "AI" label and the sparkles glyph around it still say
                    // who wrote this.
                    MarkdownText(text: message.content)
                        .font(.callout)
                }
                if !citations.isEmpty {
                    citationRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AIVisualStyle.tint)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AIVisualStyle.accent)
                .frame(width: 3)
        }
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    /// The places this answer pointed at, as references to follow.
    ///
    /// There is deliberately no "Draft comment" here. Drafting from a
    /// citation used to paste the entire answer onto that one line: an
    /// answer covers several places at once, so the result was a comment
    /// about three files anchored to one of them. A reviewer who wants a
    /// comment can write one at the line this reference takes them to, or
    /// draft from a finding in Findings, where the body is that one point.
    private var citationRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(citations.count == 1 ? "Source reference" : "Source references")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                SourceReferenceRow(
                    path: citation.path, startLine: citation.startLine, endLine: citation.endLine
                ) {
                    onNavigate(citation.path, citation.startLine)
                }
            }
        }
    }
}
