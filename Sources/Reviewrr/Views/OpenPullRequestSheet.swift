import SwiftUI

/// Opening a PR by URL stays reachable even though the dashboard is now the
/// home screen: a reviewer often gets a link in chat for a repository they
/// do not watch, and that path must not require adding a project first.
struct OpenPullRequestSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var input = ""
    @FocusState private var focused: Bool

    private var parsed: PRReference? { PRReference.parse(input) }
    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open a pull request")
                    .font(.headline)
                Text("Paste a GitHub PR URL, or type owner/repo#123.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("https://github.com/owner/repo/pull/123", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(9)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
                .focused($focused)
                .onSubmit(open)
                .help("Paste a GitHub pull request URL, or type owner/repo#123")
                .accessibilityLabel("Pull request URL or reference")
                .accessibilityHint("Press Return to open it")

            // Feedback while typing beats a disabled button with no reason:
            // an unparseable reference is the single most common failure here.
            Group {
                if !trimmed.isEmpty, parsed == nil {
                    Label("That isn't a pull request URL or owner/repo#number.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let parsed {
                    Label(parsed.key, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .motionTransition(.reviewrrRow)
            .motion(Motion.smooth, value: parsed)

            if !model.settings.recentPRs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.settings.recentPRs.prefix(5), id: \.self) { key in
                        Button {
                            input = key
                            open()
                        } label: {
                            Text(key)
                                .font(Theme.monoFontSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.reviewrr(.ghost, fullWidth: true))
                        .help("Open \(key) again")
                        .accessibilityLabel("Open recent pull request \(key)")
                    }
                }
            }

            if model.githubToken == nil {
                Label("Add a GitHub token in Settings to open private pull requests.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Try the demo PR") {
                    model.loadDemo()
                    isPresented = false
                }
                .buttonStyle(.link)
                .help("Open a bundled example pull request — no token or network needed")
                .accessibilityLabel("Open the demo pull request")

                Spacer()

                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without opening anything (Esc)")
                // ⌘. is the traditional macOS "stop" shortcut; sheets honor
                // it alongside Escape.
                Button("", action: { isPresented = false })
                    .keyboardShortcut(".", modifiers: .command)
                    .hidden()
                    // Hidden shortcut plumbing, not a control: VoiceOver has
                    // no business landing on an unlabelled empty button.
                    .accessibilityHidden(true)
                Button("Open", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
                    .help(parsed == nil
                          ? "Enter a pull request URL or owner/repo#123 first"
                          : "Open \(parsed?.key ?? "") (Return)")
                    .accessibilityLabel("Open this pull request")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { focused = true }
    }

    private func open() {
        guard let parsed else { return }
        isPresented = false
        Task { await model.open(parsed) }
    }
}
