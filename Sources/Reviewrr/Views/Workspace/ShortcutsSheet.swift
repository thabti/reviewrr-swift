import SwiftUI

/// `?` opens this from the diff pane. Plain reference sheet, no state.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let groups: [(title: String, items: [(String, String)])] = [
        ("Navigation", [
            ("j / k", "Open the next / previous file"),
            ("n / p", "Next / previous change — continues into the next file"),
            ("bar", "The same moves, floating at the bottom of the diff"),
            ("↑ ↓ ← →", "Move / collapse / expand in the file tree"),
            ("/", "Focus file search"),
        ]),
        ("Review", [
            ("v", "Mark this file viewed and open the next unread one"),
            ("v", "On a file already viewed: un-mark it and stay"),
            ("u", "Toggle unified / split diff"),
            ("drag", "Drag down the line numbers to comment on several lines"),
            ("⇧-click", "Extend the comment range to that line"),
            ("⇧⌘G", "Open this pull request on GitHub"),
            ("⇧⌘C", "Copy a reviewrr:// link to this pull request"),
        ]),
        ("Submit review", [
            ("⌘⏎", "Submit"),
            ("⌘.", "Cancel"),
        ]),
        ("Help", [
            ("?", "Show this sheet"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .help("Close this list (Esc)")
                    .accessibilityLabel("Close the keyboard shortcuts list")
                    .keyboardShortcut(.defaultAction)
            }
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items, id: \.0) { item in
                        HStack {
                            Text(item.0)
                                .font(Theme.monoFontSmall)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                .frame(minWidth: 64, alignment: .leading)
                            Text(item.1)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        // A key and its description are one fact. Read
                        // separately, VoiceOver announces "j slash k" and
                        // then, as a different element, what it does.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.1): press \(item.0)")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
