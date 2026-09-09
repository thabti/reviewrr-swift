import SwiftUI

@main
struct ReviewrrApp: App {
    @StateObject private var model = AppModel()

    /// Turns on the frame-budget probe when `REVIEWRR_PERF=1` is set, and
    /// does nothing otherwise. Here rather than in `AppModel` because the
    /// stall monitor watches the main queue, not the model.
    init() { PerfProbe.startReporting() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                // `reviewrr://owner/repo/number`. Fires both while the app
                // is running and on a launch the link itself caused, so this
                // is the only place the scheme needs handling.
                .onOpenURL { model.open(deepLink: $0) }
        }
        .windowStyle(.titleBar)
        // The toolbar draws no title: the PR chip beside it already names
        // the repository and number, and the pull request's own title is a
        // sentence long — a second copy of it in the toolbar pushed the
        // controls around and told the reviewer nothing new. `navigationTitle`
        // still names the window itself, so the Window menu, Mission Control
        // and the proxy icon keep the full title.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        // The split view declares minimum column widths; without this the
        // window can still be dragged narrower than they add up to, and the
        // columns then fight over the shortfall instead of the window
        // refusing to shrink.
        .windowResizability(.contentMinSize)
        .commands { ReviewrrCommands(model: model) }
    }
}

/// The menu bar is not decoration on macOS: it is where a reviewer discovers
/// what the app can do and what the keyboard shortcut for it is. Every
/// command here is also reachable from the UI — the menu exists so the
/// bindings are *findable*, and so ⌘-key muscle memory works before anyone
/// has read a shortcuts sheet.
private struct ReviewrrCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        // Account items go directly under "About Reviewrr", where macOS apps
        // put them. Sign-in has to be reachable from the menu bar: once the
        // reviewer has dismissed the sign-in screen to look around, the menu
        // is the only place left that can bring it back.
        // Settings is a surface in the window, not a `Settings` scene, so
        // the standard item has to be replaced rather than inherited —
        // otherwise ⌘, opens an empty floating panel beside the screen that
        // actually holds the preferences.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            if model.isSignedIn {
                Button("Sign Out of GitHub") { model.auth.signOut() }
            } else {
                Button("Sign In to GitHub…") { model.showSignIn() }
            }
        }

        // Reviewrr never creates anything, so "New" is replaced rather than
        // left as a menu item that cannot work.
        CommandGroup(replacing: .newItem) {
            Button("Command Palette…") { model.isCommandPalettePresented = true }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Open Pull Request…") { model.isOpenPRSheetPresented = true }
                .keyboardShortcut("o", modifiers: .command)

            Button("Open Demo Pull Request") { model.loadDemo() }

            Divider()

            Button("Close Pull Request") { model.closePR() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.pullRequest == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Back") { Task { await model.navigateHistory(offset: -1) } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canNavigateBack)
            Button("Forward") { Task { await model.navigateHistory(offset: 1) } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canNavigateForward)
            Divider()
            Button(model.isInspectorPresented ? "Hide Side Panel" : "Show Side Panel") {
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.pullRequest == nil)

            Picker("Side Panel", selection: $model.inspectorRail) {
                ForEach(AppModel.InspectorRail.allCases) { rail in
                    Text(rail.rawValue).tag(rail)
                }
            }
            .disabled(model.pullRequest == nil)

            Divider()

            Button("Go to Dashboard") { model.closePR() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.pullRequest == nil)
        }

        CommandMenu("Review") {
            Button("Refresh") {
                if model.pullRequest == nil {
                    Task { await model.dashboard.refreshAll(force: true) }
                } else {
                    Task { await model.reload() }
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Submit Review…") { model.isSubmitFormPresented = true }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.pullRequest == nil)

            Divider()

            Button("Mark Current File Viewed") {
                guard let file = model.selectedFile else { return }
                model.toggleViewed(file)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(model.selectedFile == nil)

            Button("Open on GitHub") {
                guard let url = model.pullRequest.flatMap({ URL(string: $0.htmlUrl) }) else { return }
                NSWorkspace.shared.open(url)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model.pullRequest == nil)

            Button("Copy Reviewrr Link") { model.copyDeepLinkForOpenPR() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.deepLinkForOpenPR == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { WorkspaceModel.shared.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(model.pullRequest == nil)
        }
    }
}
