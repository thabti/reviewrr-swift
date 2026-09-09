import AppKit
import SwiftUI

/// The window has four surfaces: sign-in when there is no credential to
/// work with, the dashboard — watched projects and the cross-repository
/// inbox — when no pull request is open, the review workspace when one is,
/// and a skeleton of that workspace while one is being fetched. Opening a
/// PR replaces the whole surface rather than pushing a sheet, because
/// review needs the full window.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var didRestoreLastPR = false

    private enum Surface: Equatable {
        case signIn, dashboard, loading, workspace, settings
    }

    /// Loading only takes over the window when there is nothing to take it
    /// over *from*. Re-fetching an open pull request leaves the reviewer
    /// where they were, with a refresh pill over the diff instead.
    ///
    /// Sign-in is checked last of the three "nothing open" cases: an
    /// already-open pull request (the demo, or one restored from a previous
    /// session) stays on screen, and a load in flight is allowed to finish.
    /// Only an empty window gets replaced by the sign-in screen.
    private var surface: Surface {
        // Settings wins over everything, including sign-in: the pane that
        // fixes "no credential" lives in there, so a reviewer who cannot sign
        // in must still be able to reach it.
        if model.isSettingsPresented { return .settings }
        if model.pullRequest != nil { return .workspace }
        if model.isLoading { return .loading }
        return model.needsSignIn ? .signIn : .dashboard
    }

    var body: some View {
        Group {
            switch surface {
            case .signIn:
                SignInView(auth: model.auth)
                    .navigationTitle("Reviewrr")
                    .transition(.identity)
            case .dashboard:
                dashboard
                    .transition(.identity)
            case .loading:
                PRLoadingView(
                    reference: model.loadingReference,
                    completedStages: model.completedLoadStages,
                    startedAt: model.loadStartedAt,
                    forge: model.settings.githubHost.forge,
                    hostName: model.settings.githubHost.isDotCom ? nil : model.settings.githubHost.displayName,
                    onCancel: { model.cancelLoad() }
                )
                // No transition: the opening screen is a plain statement of
                // what is happening, and sliding or fading it in only delays
                // the first frame that carries that information.
                .transition(.identity)
            case .workspace:
                workspace
                    .transition(.identity)
            case .settings:
                SettingsScreen()
                    .transition(.identity)
            }
        }
        // No animation between surfaces. Opening a pull request is not a
        // panel sliding in over the dashboard — it is a different screen, and
        // sliding it in from the right said "overlay", delayed the first
        // usable frame, and animated a full-window layout on the largest
        // state change in the app.
        .task {
            // Honours Settings' "Start on dashboard": when it is off, the
            // most recent pull request reopens instead. Guarded so it only
            // ever runs for the first appearance, not on every swap between
            // the surfaces.
            guard !didRestoreLastPR else { return }
            didRestoreLastPR = true

            // Registers as the notification delegate before anything can be
            // clicked. Reads the permission macOS already holds; it never
            // prompts — that only happens when the reviewer turns
            // notifications on in Settings.
            model.notifications.start()

            // A stress run has one job — land on the review workspace with a
            // pull request big enough to measure — so it skips sign-in and
            // the last-PR restore entirely.
            if StressFixture.isEnabled {
                // Frontmost, or the window renders at a reduced rate and the
                // benchmark measures a screensaver.
                NSApp.activate(ignoringOtherApps: true)
                model.loadDemo()
                return
            }

            // The credential is resolved here rather than in
            // `AppModel.init`, and this is the earliest safe place for it:
            // the window has drawn, so a Keychain approval panel (on a build
            // whose signature macOS does not recognise) appears in response
            // to the reviewer opening the app rather than over an empty
            // screen. `needsSignIn` treats "not looked yet" as signed in, so
            // until this returns the dashboard shows — never a flash of the
            // sign-in screen at someone who has a token.
            model.loadTokenIfNeeded()

            // Reopening the last pull request needs a credential. Without
            // one it would fail into an error alert stacked on top of the
            // sign-in screen, which reads as a broken app rather than one
            // asking to be signed in.
            guard model.isSignedIn else { return }

            guard !model.settings.startOnDashboard,
                  let recent = model.settings.recentPRs.first,
                  let reference = PRReference.parse(recent)
            else { return }
            await model.open(reference)
        }
        // Injected once, so every "not configured" strip in the app can send
        // the reviewer to the pane that fixes it without holding `AppModel`.
        .environment(\.openSettingsPane, OpenSettingsAction { model.openSettings($0) })
        // Published once, for every chip that turns an issue key into a link.
        .environment(\.issueTracker, model.settings.issueTracker)
        // A notification clicked in Notification Centre lands here: the
        // service records the reference, the window opens it. Routed through
        // the view rather than straight from the service so it behaves
        // exactly like a deep link, including the surface switch.
        .onChange(of: model.notifications.pendingOpen) { _, reference in
            guard let reference else { return }
            model.notifications.consumePendingOpen()
            model.closeSettings()
            Task { await model.open(reference) }
        }
        .safeAreaInset(edge: .top) {
            if let error = model.draftSaveError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry Save") { model.retryDraftSave() }
                }
                .font(.callout)
                .padding(12)
                .background(Theme.cardBackground)
            }
        }
        .sheet(isPresented: $model.isCommandPalettePresented) {
            CommandPaletteView(model: model.palette, isPresented: $model.isCommandPalettePresented)
        }
        .sheet(isPresented: $model.isOpenPRSheetPresented) {
            OpenPullRequestSheet(isPresented: $model.isOpenPRSheetPresented)
                .environmentObject(model)
        }
        .alert("Couldn't load pull request", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.loadError = nil }
        } message: {
            Text(model.loadError ?? "")
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        DashboardView(model: model.dashboard) { reference, host in
            Task { await model.open(reference, host: host) }
        }
        .navigationTitle("Reviewrr")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) { historyButtons }
            ToolbarItem(placement: .principal) {
                Picker("Dashboard", selection: $model.dashboard.showsSavedReviews) {
                    Text(model.settings.githubHost.forge.changeNounCapitalized + "s").tag(false)
                    Text("Continue Reviewing (\(model.dashboard.savedReviews.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                .accessibilityLabel("Dashboard tab")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.isOpenPRSheetPresented = true } label: {
                    Label("Open pull request", systemImage: "link")
                }
                .help("Open a pull request by URL (⌘O)")
                .accessibilityLabel("Open a pull request by URL")
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    Task { await model.dashboard.refreshAll(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh watched projects (⌘R)")
                .accessibilityLabel("Refresh watched projects")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.dashboard.isRefreshingAll)

                settingsButton
            }
        }
    }

    // MARK: - Review workspace

    private var workspace: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            DiffContainerView()
                .safeAreaInset(edge: .top, spacing: 0) { titleBar }
                // Names the window — Window menu, Mission Control, proxy
                // icon — as well as the title bar above. The toolbar itself
                // still draws no title (`showsTitle: false` in
                // `ReviewrrApp`): a centred toolbar title shrinks to fit
                // between the two control groups, which is the opposite of
                // what a sentence-long PR title needs.
                .navigationTitle(model.pullRequest?.title ?? "Reviewrr")
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                historyButtons
                Button { model.closePR() } label: {
                    Label("Dashboard", systemImage: "house")
                }
                .help("Return to dashboard")
                .accessibilityLabel("Return to dashboard")

                if let pr = model.pullRequest, let reference = model.reference {
                    PRHeaderView(pr: pr, reference: reference, checkRollup: model.conversation.checkRollup)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh this pull request (⌘R)")
                .accessibilityLabel("Refresh this pull request")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoading)

                SubmitReviewButton()

                // The rail switcher is in the inspector's own band, not here
                // — see `inspector`. What stays in the window's toolbar is
                // the way to *open* the panel, which is the one thing that
                // cannot live inside it.
                if !model.isInspectorPresented {
                    Button { model.isInspectorPresented = true } label: {
                        Label("Show Side Panel", systemImage: "sidebar.trailing")
                    }
                    .help("Show side panel (⌥⌘I)")
                    .accessibilityLabel("Show side panel")
                }

                settingsButton
            }
        }
    }

    /// The pull request's title, across the full width of the content
    /// column.
    ///
    /// It used to live only in the window title and the PR chip's tooltip,
    /// on the reasoning that a second copy in the toolbar pushed the
    /// controls around — true of the *toolbar*, but it left the one sentence
    /// that says what this change is for nowhere on screen. Given its own
    /// row it costs no horizontal room from anything: the title gets the
    /// whole column instead of competing with the toolbar's controls.
    ///
    /// Inset into the detail column rather than above the split view, so the
    /// sidebar and the inspector keep their own full height.
    @ViewBuilder
    private var titleBar: some View {
        if let pr = model.pullRequest {
            VStack(spacing: 0) {
                // Deliberately plain: one line, a trailing `Spacer` for the
                // width, and no `fixedSize`.
                //
                // The first version asked for `maxWidth: .infinity` *and*
                // `fixedSize(horizontal: false, vertical: true)` inside this
                // inset. A `safeAreaInset` measures its content with an
                // unbounded width proposal, so that pair reports an ideal
                // width of "as much as exists", the window grows to satisfy
                // it, and the next constraint pass asks again — the app died
                // with `NSGenericException: … more Update Constraints in
                // Window passes than there are views in the window` and a
                // window 44,179 points wide.
                HStack(spacing: 0) {
                    Text(pr.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.panelHeaderHeight)
                // The whole title on hover, so truncation never hides its end.
                .help(pr.title)
                .accessibilityAddTraits(.isHeader)
                Divider()
            }
            .background(Theme.panelMaterial)
        }
    }

    /// Panel selection and dismissal live together in the inspector toolbar.
    private var inspector: some View {
        Group {
            switch model.inspectorRail {
            case .ai:
                AIPanelView(
                    model: model.ai,
                    rail: $model.inspectorRail,
                    onNavigate: { path, line in model.workspace.jump(to: path, line: line) },
                    onCreateDraft: { path, line, side, body in
                        model.addDraftComment(path: path, line: line, side: side, body: body)
                        // Drafting from a finding used to look like nothing
                        // happened: the draft lands inline in the diff, and
                        // the file it belongs to is often folded (marked
                        // viewed) or filtered out of the pane. Taking the
                        // reviewer to what they just created unfolds it.
                        model.workspace.jump(to: path, line: line, side: side)
                    }
                )
            case .conversation:
                ConversationPanelView(model: model.conversation, rail: $model.inspectorRail) { path, line, side in
                    model.workspace.jump(to: path, line: line, side: side)
                }
            }
        }
        .motion(Motion.surface, value: model.inspectorRail)
        .toolbar {
            ToolbarItemGroup {
                // Which panel, at the top of the panel it changes.
                //
                // It spent a while in the window's toolbar, on the reasoning
                // that a switcher inside the inspector cannot be pressed
                // while the inspector is hidden. True, and it turned out not
                // to matter: nobody reaches for "Conversation" while looking
                // at a collapsed panel — they open the panel first. The
                // control reads better beside the thing it changes than among
                // the pull request's own actions.
                InspectorRailSwitcher(selection: $model.inspectorRail)

                Spacer()

                // The same glyph that shows the panel, not an X.
                //
                // An X means "dismiss this thing" — a sheet, an alert, a tag.
                // The inspector is not dismissed, it is *collapsed*, and it
                // comes back with the identical control on the other side of
                // the toolbar. Wearing `sidebar.trailing` in both states says
                // that: one button, one meaning, and it matches what every
                // other Mac app puts there.
                Button { model.isInspectorPresented = false } label: {
                    Label("Hide Side Panel", systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help("Hide side panel (⌥⌘I)")
                .accessibilityLabel("Hide side panel")
            }
        }
    }

    @ViewBuilder
    private var historyButtons: some View {
        Button { Task { await model.navigateHistory(offset: -1) } } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .disabled(!model.canNavigateBack)
        .help("Back (⌘[)")
        .accessibilityLabel("Go back")
        Button { Task { await model.navigateHistory(offset: 1) } } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .disabled(!model.canNavigateForward)
        .help("Forward (⌘])")
        .accessibilityLabel("Go forward")
    }

    /// Settings, in both toolbars.
    ///
    /// A plain button now rather than `SettingsLink`: configuration is a
    /// surface in this window, not a floating panel, so there is no scene to
    /// reach and nothing to bring forward. A token that needs pasting or a
    /// provider that needs a key is otherwise only reachable through the menu
    /// bar, which is the last place someone looks when the thing in front of
    /// them says it is not configured.
    private var settingsButton: some View {
        Button {
            model.openSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings (⌘,)")
        .accessibilityLabel("Open Settings")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.loadError != nil }, set: { if !$0 { model.loadError = nil } })
    }
}
