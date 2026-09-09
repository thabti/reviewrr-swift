import SwiftUI

/// The configuration screen: a sidebar of panes beside the pane itself,
/// filling the window.
///
/// It replaced a floating `Settings` window with a tab bar, for the same
/// reasons the review workspace is a screen rather than an overlay. A tab bar
/// caps out at six items and gives each one two words to explain itself; a
/// utility window fixed at 580pt then had to scroll panes that would have fit
/// comfortably in the window behind it, and it sat on top of the thing the
/// reviewer was configuring. This is a place you go and come back from — the
/// pattern macOS's own System Settings moved to, and the one the rest of this
/// app already uses.
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeSettings()
                } label: {
                    Label("Done", systemImage: "chevron.backward")
                }
                .help("Close settings and go back (Esc)")
                .accessibilityLabel("Close settings")
            }
        }
        // Esc leaves, the way it does out of every other full-window state in
        // the app. A `Button` rather than `onExitCommand` so it also works
        // when focus is inside a text field in one of the panes.
        .background {
            Button("") { model.closeSettings() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var sidebar: some View {
        List(selection: paneSelection) {
            Section {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink(value: pane) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pane.label)
                                    .font(Theme.bodyMedium)
                                // The one-line summary is what makes a
                                // six-item settings list answerable without
                                // clicking all six.
                                Text(pane.summary)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: pane.systemImage)
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 3)
                    }
                    .help(pane.summary)
                    .accessibilityLabel("\(pane.label). \(pane.summary)")
                }
            } header: {
                Text("Settings")
            }
        }
        .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 280)
        .safeAreaInset(edge: .bottom) { credentialFooter }
    }

    /// Who is signed in, and where — the one piece of state that decides
    /// whether anything else in here can work, so it is visible from every
    /// pane rather than only from Account.
    private var credentialFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.isSignedIn ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.isSignedIn ? .green : .orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.isSignedIn ? "Signed in" : "Not signed in")
                        .font(Theme.caption)
                    Text(model.settings.githubHost.displayName)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .help(model.isSignedIn
              ? "Signed in to \(model.settings.githubHost.displayName)"
              : "No credential for \(model.settings.githubHost.displayName) — see the Account pane")
        .accessibilityElement(children: .combine)
    }

    /// `NavigationLink(value:)` needs a non-optional selection to highlight a
    /// row, but `List(selection:)` on macOS insists on an optional. Bridged
    /// here so deselecting (⌘-click on the selected row) puts the selection
    /// back rather than leaving an empty detail pane.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { model.settingsPane },
            set: { if let new = $0 { model.settingsPane = new } }
        )
    }

    /// The pane, with its heading pinned above it.
    ///
    /// Deliberately not inside a `ScrollView`: every pane is a grouped
    /// `Form`, which scrolls itself. Nesting the two makes the form collapse
    /// to its ideal height inside an outer scroller and the sections stop
    /// filling the window. The heading sits outside the scroll instead, so it
    /// stays put while a long pane moves under it.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            pane
        }
        // A settings form has a comfortable reading width the way a paragraph
        // does. Filling a 1,400pt window puts a row's label and its control a
        // hand's width apart.
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.settingsPane.label)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.settingsPane.label)
                // Settings uses the system's own type scale, not the review
                // column's compact 11/12pt one: this is a reading surface
                // with room, and it should look like the rest of macOS's
                // settings rather than like a diff gutter.
                .font(.title2.weight(.semibold))
            Text(model.settingsPane.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var pane: some View {
        switch model.settingsPane {
        case .account: AccountSettingsView(auth: model.auth)
        case .general: GeneralSettingsView()
        case .notifications: NotificationSettingsView()
        case .integrations: IntegrationsSettingsView()
        case .watchlist: WatchlistSettingsView()
        case .ai: AISettingsView(pane: AnyView(AIProviderSettingsView(model: model.ai)))
        case .data: DataSettingsView()
        }
    }
}

/// "Take me to the setting that fixes this", as an environment action.
///
/// Every empty state and every "not configured" strip in the app offers a way
/// into settings, and none of them should have to hold `AppModel` to do it —
/// the AI panel takes an `AIModel`, the picker takes a `RepositoryPickerModel`.
/// The same shape as `openURL`: injected once by the root view, a no-op
/// everywhere else, so a preview still renders.
struct OpenSettingsAction {
    private let handler: (SettingsPane?) -> Void

    init(handler: @escaping (SettingsPane?) -> Void) {
        self.handler = handler
    }

    /// Opens settings, at `pane` when the caller knows which one is relevant.
    func callAsFunction(_ pane: SettingsPane? = nil) { handler(pane) }
}

private struct OpenSettingsActionKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction { _ in }
}

extension EnvironmentValues {
    var openSettingsPane: OpenSettingsAction {
        get { self[OpenSettingsActionKey.self] }
        set { self[OpenSettingsActionKey.self] = newValue }
    }
}
