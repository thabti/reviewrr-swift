import AppKit
import SwiftUI

struct AIAskComposerView: View {
    @ObservedObject var model: AIModel
    @ObservedObject var composer: AIAskComposerModel
    @State private var editorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !composer.taggedPaths.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(composer.taggedPaths, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                Text(composer.paths.contains(path) ? path : "\(path) — no longer in PR").lineLimit(2).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button { composer.taggedPaths.removeAll { $0 == path } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(path) from this question")
                                .accessibilityLabel("Remove tagged file \(path)")
                            }
                            .font(.caption)
                            .foregroundStyle(composer.paths.contains(path) ? Theme.accent : .red)
                            .padding(6)
                            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            .help(path)
                        }
                    }
                }
                .frame(height: min(CGFloat(composer.taggedPaths.count) * 44, 96))
            }
            ComposerShell(
                placeholder: "",
                tint: AIVisualStyle.accent,
                isFocused: editorFocused,
                minHeight: 64
            ) {
                AnyView(
                    ZStack(alignment: .topLeading) {
                        AIAskTextEditor(composer: composer, isFocused: $editorFocused)
                            .frame(height: 64)
                        if composer.text.isEmpty {
                            ComposerShell<EmptyView, EmptyView>.placeholderText(
                                "Ask about this pull request — @ to tag a file, ⌘⏎ to send"
                            )
                            .padding(.vertical, 2)
                        }
                    }
                )
            } chips: {
                Button { composer.showPicker() } label: {
                    ComposerChip(systemImage: "at", tint: AIVisualStyle.accent) {
                        Text(composer.taggedPaths.isEmpty ? "Whole PR" : "\(composer.taggedPaths.count) files")
                    }
                }
                .buttonStyle(.plain)
                .help("Tag changed files to narrow what the assistant reads. Untagged, the scope is the whole pull request.")
                .accessibilityLabel(composer.taggedPaths.isEmpty
                                    ? "Scope: whole pull request. Tag files"
                                    : "Scope: \(composer.taggedPaths.count) tagged files")

                ComposerChip(systemImage: "cpu") {
                    Text(model.modelID.isEmpty
                         ? AIProviderRegistry.descriptor(for: model.providerID).defaultModel
                         : model.modelID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help("Answering with \(AIProviderRegistry.descriptor(for: model.providerID).displayName)")
                .accessibilityLabel("Model: \(model.modelID)")
            } action: {
                ComposerSendButton(
                    tint: AIVisualStyle.accent,
                    isBusy: model.isAsking,
                    isEnabled: canSend,
                    sendHelp: "Send question (⌘⏎)",
                    busyHelp: "Stop this reply",
                    onSend: send,
                    onStop: { model.cancel() }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        // Suggestions float over the transcript; opening autocomplete must
        // never increase the composer's height or push Send below the window.
        .overlay(alignment: .top) {
            if composer.mentionRange != nil {
                filePicker
                    .padding(.horizontal, 12)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 4 }
            }
        }
        .zIndex(1)
    }

    private var canSend: Bool {
        !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && composer.mentionRange == nil
            && composer.taggedPaths.allSatisfy { composer.paths.contains($0) }
    }

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PR Files").font(.caption.weight(.semibold))
                Spacer()
                Text("↑↓ choose · Return tag · Esc close").font(.caption2).foregroundStyle(.secondary)
            }
            if composer.matches.isEmpty {
                Text(composer.paths.isEmpty ? "No changed files available." : "No matching untagged files. Try another name or path.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(composer.matches.enumerated()), id: \.element) { index, path in
                                Button { composer.choose(path) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text((path as NSString).lastPathComponent).font(.callout.weight(.medium))
                                            Text(path).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == composer.selectedIndex ? Theme.accent.opacity(0.16) : .clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .id(index)
                                .help(path)
                                .accessibilityLabel("Tag \(path)")
                                .accessibilityAddTraits(index == composer.selectedIndex ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: min(CGFloat(composer.matches.count) * 48, 192))
                    .onChange(of: composer.selectedIndex) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }

    private func send() {
        guard canSend, !model.isAsking else { return }
        let text = composer.text
        let scope = composer.scope
        composer.reset()
        Task { await model.ask(text, scope: scope) }
    }
}

/// NSTextView supplies a UTF-16 caret position on macOS 14, so autocomplete
/// edits the mention under the cursor rather than assuming typing is at the end.
private struct AIAskTextEditor: NSViewRepresentable {
    @ObservedObject var composer: AIAskComposerModel

    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(composer: composer) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = AIAskNativeTextView(frame: .zero)
        editor.minSize = NSSize(width: 0, height: 64)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.onFocus = { focused in
            // A structured hop rather than `DispatchQueue.main.async`: this
            // view is already on the main actor, and a `Task` inherits it.
            Task { isFocused = focused }
        }
        scroll.documentView = editor
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.setAccessibilityLabel("Ask a question. Type at sign to tag PR files.")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.updating = true
        if editor.string != composer.text { editor.string = composer.text }
        if editor.selectedRange() != composer.selection { editor.setSelectedRange(composer.selection) }
        if context.coordinator.focusRequest != composer.focusRequest {
            context.coordinator.focusRequest = composer.focusRequest
            editor.window?.makeFirstResponder(editor)
        }
        context.coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let composer: AIAskComposerModel
        var updating = false
        var focusRequest = 0
        init(composer: AIAskComposerModel) { self.composer = composer }

        func textDidChange(_ notification: Notification) { update(notification) }
        func textViewDidChangeSelection(_ notification: Notification) { update(notification) }
        private func update(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            composer.update(text: editor.string, selection: editor.selectedRange())
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            composer.handle(NSStringFromSelector(commandSelector))
        }
    }
}

private final class AIAskNativeTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocus?(false) }
        return result
    }
}
