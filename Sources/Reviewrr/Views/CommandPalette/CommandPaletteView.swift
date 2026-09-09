import SwiftUI

/// The ⌘K palette: type a few letters, hit Return.
///
/// Presented as a sheet rather than a floating panel so it inherits the
/// window's focus and dismissal behaviour, and so Escape works without any
/// key handling of our own.
struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    @Binding var isPresented: Bool

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .background(Theme.panelMaterial)
        .task {
            model.open()
            queryFocused = true
        }
        .onDisappear { model.close() }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            TextField("Search commands, files, and pull requests…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($queryFocused)
                .onSubmit(runSelection)
                .accessibilityLabel("Command search")

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        // Arrow keys must steer the list while the text field keeps focus,
        // so they are intercepted here rather than on the rows.
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groupedResults, id: \.group) { section in
                        Section {
                            ForEach(section.commands) { command in
                                row(for: command)
                                    .id(command.id)
                            }
                        } header: {
                            Text(section.group.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.barMaterial)
                        }
                    }

                    if model.results.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                            Text("No commands match “\(model.query)”")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectionIndex) { _, _ in
                guard let selected = model.selectedCommand else { return }
                withAnimation(Motion.snappy) { proxy.scrollTo(selected.id, anchor: .center) }
            }
        }
    }

    private func row(for command: PaletteCommand) -> some View {
        let isSelected = model.selectedCommand?.id == command.id
        return Button {
            run(command)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle = command.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(Theme.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(command.isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.16) : .clear)
                .padding(.horizontal, 8)
        )
        .motion(Motion.hover, value: isSelected)
        // Hover selects rather than merely tinting, so pointer and keyboard
        // never disagree about which command Return will run.
        .onHover { hovering in
            guard hovering, let index = model.results.firstIndex(where: { $0.id == command.id }) else { return }
            model.selectionIndex = index
        }
        .accessibilityLabel(command.title)
        .accessibilityHint(command.subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.subtitle.map { "\(command.title), \($0)" } ?? command.title)
        .accessibilityHint(command.shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(command.subtitle ?? command.title)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↩", "Run")
            hint("esc", "Dismiss")
            Spacer()
            if !model.results.isEmpty {
                Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motion(Motion.smooth, value: model.results.count)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.barMaterial)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Theme.monoFontSmall)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(label)")
    }

    // MARK: - Running

    private func runSelection() {
        guard let command = model.selectedCommand else { return }
        run(command)
    }

    private func run(_ command: PaletteCommand) {
        // A disabled command keeps the palette open: its subtitle usually
        // says what is missing, so dismissing would hide the answer.
        guard model.run(command) else { return }
        isPresented = false
    }
}
