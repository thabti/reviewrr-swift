import SwiftUI

/// `?` opens this from the diff pane, ⌘/ from the Help menu. Plain
/// reference sheet, no state.
///
/// Every row is rendered from `Shortcut`, the list the menu bar binds and
/// the ⌘K palette prints. It used to be a table typed out by hand, which is
/// how it came to advertise ⌘. for a Cancel nothing bound, list 4 of ~16 ⌘
/// bindings without ⌘K among them, and repeat `"v"` as a `ForEach` id so one
/// of the two behaviours it documented never appeared on screen at all.
/// Nothing here decides what a key does or what it is called: it prints what
/// the catalog says, so a binding that changes changes here too.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .help("Close this list (Esc or Return)")
                    .accessibilityLabel("Close the keyboard shortcuts list")
                    .keyboardShortcut(.defaultAction)
            }

            // Long enough now to need scrolling: the whole keyboard is here
            // rather than the four bindings whoever wrote the table
            // remembered.
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(Shortcut.Group.allCases) { group in
                        section(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 430, height: 560)
        // Esc closes it, the way it closes every other dismissible surface
        // in the app — this sheet was the one that promised Esc in its own
        // tooltip and bound only Return. A hidden `Button` rather than
        // `onExitCommand`, matching `SettingsScreen`: it keeps working with
        // focus anywhere inside the sheet.
        .background {
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func section(_ group: Shortcut.Group) -> some View {
        let rows = Shortcut.sheetRows(in: group)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { keyRow($0) }
            }
        }
    }

    private func keyRow(_ row: Shortcut.SheetRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.keys)
                .font(Theme.monoFontSmall)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 64, alignment: .leading)
            Text(row.action)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        // A key and its description are one fact. Read separately,
        // VoiceOver announces "v slash shift command V" and then, as a
        // different element, what it does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.action): press \(row.keys)")
    }
}
