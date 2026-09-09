import AppKit
import SwiftUI

struct AIAskComposerView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: AIModel
    @ObservedObject var composer: AIAskComposerModel
    @State private var editorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !composer.taggedPaths.isEmpty { taggedFiles }
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
                        Text(scopeChipLabel)
                    }
                }
                .buttonStyle(.plain)
                .help("Tag changed files to narrow what the assistant reads. Untagged, the scope is the whole pull request.")
                .accessibilityLabel(composer.taggedPaths.isEmpty
                                    ? "Scope: whole pull request. Tag files"
                                    : "Scope: \(composer.taggedPaths.count) tagged files. Tag more")

                modelChip
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

    /// The scope chip names the one file when there is one, because
    /// "1 files" is the kind of thing that makes an app look unfinished, and
    /// the filename is more use than the count anyway.
    private var scopeChipLabel: String {
        switch composer.taggedPaths.count {
        case 0: return "Whole PR"
        case 1: return (composer.taggedPaths[0] as NSString).lastPathComponent
        default: return "\(composer.taggedPaths.count) files"
        }
    }

    // MARK: - Model

    /// The chip that used to state which model would answer, and now
    /// changes it.
    ///
    /// Only the **selected** provider's models are listed. The menu used to
    /// flatten every ready provider into one list — Apple Intelligence, three
    /// Ollama models, three Codex models, and a "Default model" for each ACP
    /// agent — a dozen items to answer a question the reviewer usually asks
    /// about the provider they are already on.
    ///
    /// Switching provider is still possible without a trip to Settings, one
    /// level down in a submenu, because it was possible here before and
    /// removing it would be a loss. Ready providers only: an entry that
    /// fails with "not configured" is worse than one that is not there.
    private var modelChip: some View {
        Menu {
            if let current = currentProvider {
                Section(current.displayName) {
                    modelItems(for: current)
                }
            }

            if !otherProviders.isEmpty {
                Divider()
                Menu("Switch provider") {
                    ForEach(otherProviders) { descriptor in
                        // Switching lands on that provider's own default,
                        // which is the only model it can be known to have.
                        Button(descriptor.displayName) {
                            model.selectProviderModel(
                                providerID: descriptor.id,
                                modelID: descriptor.models.first?.modelID ?? ""
                            )
                        }
                    }
                }
            }

            if model.readyProviders.isEmpty {
                Text("No provider is configured yet")
            }
            Divider()
            Button("Providers and Models…") { openSettings(.ai) }
        } label: {
            ComposerChip(systemImage: "cpu") {
                Text(model.currentModelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Answering with \(AIProviderRegistry.descriptor(for: model.providerID).displayName). Click to change.")
        .accessibilityLabel("Model: \(model.currentModelLabel). Change model")
    }

    /// The provider currently answering, when it is one of the ready ones.
    ///
    /// A reviewer can have a provider selected that is no longer ready — a
    /// CLI they uninstalled, a key they removed — and the menu says nothing
    /// about it rather than listing a provider that cannot answer.
    private var currentProvider: AIProviderDescriptor? {
        model.readyProviders.first { $0.id == model.providerID }
    }

    private var otherProviders: [AIProviderDescriptor] {
        model.readyProviders.filter { $0.id != model.providerID }
    }

    @ViewBuilder
    private func modelItems(for descriptor: AIProviderDescriptor) -> some View {
        if descriptor.models.isEmpty {
            // Apple Intelligence and the ACP agents choose their own model;
            // the provider is the whole choice.
            modelItem(
                label: descriptor.defaultModel.isEmpty ? "Default model" : descriptor.defaultModel,
                provider: descriptor.id,
                modelID: ""
            )
        } else {
            ForEach(descriptor.models) { option in
                modelItem(label: option.label, provider: descriptor.id, modelID: option.modelID)
            }
        }
    }

    private func modelItem(label: String, provider: String, modelID: String) -> some View {
        let isCurrent = model.providerID == provider
            && (model.modelID == modelID || (modelID.isEmpty && model.modelID.isEmpty))
        // A `Toggle` rather than a `Picker`: this is how AppKit draws a
        // checked menu item, and the selection spans several sections — the
        // current model may even be one the reviewer typed into Settings by
        // hand, which no tag in this menu would match.
        return Toggle(label, isOn: Binding(
            get: { isCurrent },
            set: { isOn in
                guard isOn else { return }
                model.selectProviderModel(providerID: provider, modelID: modelID)
            }
        ))
    }

    // MARK: - Tagged files

    /// What this question is scoped to, as a wrapping row of chips.
    ///
    /// It was a vertical scrolling list of full-width rows, 44pt each,
    /// capped at 96 — so three tagged files ate a third of the composer and
    /// hid the rest behind a scrollbar, in a 400pt rail. Tags are short and
    /// there are rarely many: they wrap.
    private var taggedFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.xs) {
                Text(composer.taggedPaths.count == 1 ? "1 file tagged" : "\(composer.taggedPaths.count) files tagged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !composer.staleTaggedPaths.isEmpty {
                    Button("Drop missing") { composer.dropStaleTags() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("Remove the tagged files that are no longer in this pull request")
                }
                Button("Clear") { composer.untagAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Ask about the whole pull request instead")
            }

            ScrollView(.vertical) {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(composer.taggedPaths, id: \.self) { path in
                        taggedChip(path)
                    }
                }
            }
            .frame(maxHeight: 74)
        }
    }

    private func taggedChip(_ path: String) -> some View {
        let file = composer.file(for: path)
        let isStale = file == nil
        return HStack(spacing: 4) {
            if let file {
                FileStatusIcon(status: file.status)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
            }
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { composer.untag(path) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tagged file \(path)")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isStale ? Color.red : AIVisualStyle.accent)
        .padding(.horizontal, Theme.chipPaddingHorizontal)
        .padding(.vertical, Theme.chipPaddingVertical)
        .background((isStale ? Color.red : AIVisualStyle.accent).opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder((isStale ? Color.red : AIVisualStyle.accent).opacity(0.35)))
        // The full path is the tooltip, not the label: a 60-character path
        // in a chip row wraps to three lines and hides the other tags.
        .help(isStale ? "\(path) — no longer in this pull request" : path)
        .accessibilityLabel(isStale ? "\(path), no longer in this pull request" : path)
    }

    private var canSend: Bool {
        !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && composer.mentionRange == nil
            && composer.everyTagIsLive
    }

    // MARK: - File picker

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.xs) {
                Text("Changed files").font(.caption.weight(.semibold))
                // How much of the pull request is on screen. Without it a
                // scrolling list of ten in a 300-file PR looks like the
                // whole answer, and there is no way to tell a query that
                // narrowed well from one that matched almost nothing.
                Text(countSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("↑↓ · ⏎ tag · esc").font(.caption2).foregroundStyle(.secondary)
            }
            pickerList(composer.matches)
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }

    /// The matches are passed down rather than re-read: `body` needs them
    /// for the empty check, the rows and the height, and each read used to
    /// re-rank every changed file in the pull request.
    @ViewBuilder
    private func pickerList(_ matches: [String]) -> some View {
        if matches.isEmpty {
            emptyPicker
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                            pickerRow(path: path, index: index)
                        }
                    }
                }
                .frame(height: min(CGFloat(matches.count) * 34, 204))
                .onChange(of: composer.selectedIndex) { _, index in proxy.scrollTo(index) }
            }
        }
    }

    /// "12 of 340" while filtering, the plain total when not — the second
    /// number is only interesting once something has been excluded.
    private var countSummary: String {
        let total = composer.paths.count
        let shown = composer.matches.count
        return shown == total ? "\(total)" : "\(shown) of \(total)"
    }

    /// Three distinct dead ends, because they need three different actions:
    /// no diff at all, everything already tagged, or a query that matched
    /// nothing.
    private var emptyPicker: some View {
        Group {
            if composer.paths.isEmpty {
                Text("This pull request has no changed files to tag.")
            } else if composer.taggedPaths.count == composer.paths.count {
                Text("Every changed file is already tagged.")
            } else {
                Text("Nothing matches “\(composer.mentionQuery)”. Try part of a filename, or a folder.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    /// One row: what changed, what it is called, where it lives, and how big
    /// the change is.
    ///
    /// It used to be a two-line stack of filename over full path, 48pt tall,
    /// with the same grey document glyph on every row — so four rows filled
    /// the list and none of them said anything the others did not. One line
    /// each now: the status glyph the file tree already uses, the name, the
    /// directory dimmed behind it, and the diff stat at the trailing edge.
    private func pickerRow(path: String, index: Int) -> some View {
        let file = composer.file(for: path)
        let directory = (path as NSString).deletingLastPathComponent
        let isSelected = index == composer.selectedIndex
        return Button { composer.choose(path) } label: {
            HStack(spacing: 6) {
                if let file {
                    FileStatusIcon(status: file.status)
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
                Text((path as NSString).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if !directory.isEmpty {
                    // Truncated from the head: the end of a path is what
                    // distinguishes two files with the same name, and the
                    // repository root prefix that every row shares is not.
                    Text(directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Theme.Space.xs)
                if let file {
                    DiffStatCounts(additions: file.additions, deletions: file.deletions)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .id(index)
        .help(path)
        .accessibilityLabel(accessibilityLabel(path: path, file: file))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(path: String, file: PRFile?) -> String {
        guard let file else { return "Tag \(path)" }
        return "Tag \(path), \(file.status.rawValue), \(file.additions) added, \(file.deletions) removed"
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
