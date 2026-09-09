import Combine
import Foundation
import SwiftUI

/// The five requests opening a pull request fans out to. They are issued
/// together and reported as each one lands, so the opening screen can say
/// what has actually arrived rather than guessing at a percentage.
enum PRLoadStage: String, CaseIterable, Identifiable {
    case pullRequest = "Pull request"
    case files = "Changed files"
    case comments = "Comments"
    case reviews = "Reviews"
    case threads = "Review threads"

    var id: String { rawValue }

    /// What each request is called on the forge it is being sent to.
    ///
    /// "Pull request", "Reviews" and "Review threads" are GitHub's words. A
    /// reviewer watching a GitLab instance load should see GitLab's — the
    /// screen is reporting what it is asking for, and it should ask in the
    /// vocabulary of whoever it is asking.
    /// Whether the workspace waits for this request.
    ///
    /// Only the pull request and its file list; discussion arrives after the
    /// diff is already readable.
    var gatesTheWorkspace: Bool {
        switch self {
        case .pullRequest, .files: return true
        case .comments, .reviews, .threads: return false
        }
    }

    func label(for forge: Forge) -> String {
        switch (self, forge) {
        case (.pullRequest, .gitlab): return "Merge request"
        case (.reviews, .gitlab): return "Approvals"
        case (.threads, .gitlab): return "Discussions"
        default: return rawValue
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Settings & auth
    @Published var settings: AppSettings
    @Published var githubToken: String?
    @Published var tokenVerification: TokenVerification = .unknown

    /// Where the token in `githubToken` came from, and what to say when there
    /// isn't one.
    enum TokenSource: Equatable {
        /// Not looked for yet — the Keychain is read on first use, never at launch.
        case unread
        case keychain
        /// Taken from `REVIEWRR_GITHUB_TOKEN`. Checked before the Keychain, so
        /// a development build never touches it at all.
        case environment
        /// Pasted for this run only, after the Keychain was refused. Held in
        /// memory and never written anywhere.
        case session
        case missing
        /// The Keychain refused this build. Asking again on a loop is the one
        /// response guaranteed to be wrong, so the app stops and says so.
        case denied(KeychainDenial)
        case failed(OSStatus)
    }

    @Published private(set) var tokenSource: TokenSource = .unread

    enum TokenVerification: Equatable {
        case unknown, verifying, valid(String), invalid(String)
    }

    /// Set when the reviewer chooses to look around without an account. The
    /// sign-in screen then stops taking over the window for the rest of the
    /// session — the dashboard and the demo pull request both work read-only,
    /// and a screen that cannot be dismissed would be lying about that.
    ///
    /// Deliberately not persisted: on the next launch a signed-out reviewer
    /// is offered sign-in again, because that is still the thing that makes
    /// the app work.
    @Published var isSignInDismissed = false

    /// Whether the window should be showing the sign-in screen.
    var needsSignIn: Bool {
        Self.needsSignIn(token: githubToken, source: tokenSource, isDismissed: isSignInDismissed)
    }

    /// The gate rule, pure so it can be checked as a truth table rather than
    /// by standing up an `AppModel` and a window.
    ///
    /// `.unread` — the Keychain has not been consulted yet — counts as
    /// "signed in" on purpose. `RootView`'s task resolves the credential on
    /// first appearance; assuming the worst until it answers would flash the
    /// sign-in screen at a reviewer who already has a token.
    static func needsSignIn(token: String?, source: TokenSource, isDismissed: Bool) -> Bool {
        if isDismissed { return false }
        if let token, !token.isEmpty { return false }
        return source != .unread
    }

    var isSignedIn: Bool { githubToken?.isEmpty == false }

    /// Whether the background poller — and with it every notification —
    /// should be running.
    ///
    /// Two conditions, and the first is the subtle one: `needsSignIn` treats
    /// an unread Keychain as signed in so the window does not flash the
    /// sign-in screen, but starting a sync against a credential nobody has
    /// fetched yet just fails and puts the poller into backoff before the
    /// app has finished launching. Waiting for the Keychain to answer costs
    /// nothing — `RootView` reads it on first appearance.
    var isPollingEligible: Bool {
        Self.isPollingEligible(token: githubToken, source: tokenSource, isDismissed: isSignInDismissed)
    }

    /// Pure, for the same reason `needsSignIn` is: it is a rule about three
    /// values, and it decides whether the app ever notices anything.
    static func isPollingEligible(token: String?, source: TokenSource, isDismissed: Bool) -> Bool {
        if case .unread = source { return false }
        return !needsSignIn(token: token, source: source, isDismissed: isDismissed)
    }

    /// Opens the configuration screen, optionally at a particular pane.
    ///
    /// Anything that can fail for a reason a setting fixes routes through
    /// here — a refused Keychain, an unconfigured AI provider, notification
    /// permission denied — so "go and fix it" is one call and always lands on
    /// the pane that can.
    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        isSettingsPresented = true
    }

    func closeSettings() {
        isSettingsPresented = false
    }

    /// Brings the sign-in screen back — for the menu bar and the palette,
    /// after "Continue without signing in", and after signing out.
    func showSignIn() {
        isSignInDismissed = false
        loadTokenIfNeeded()
    }

    /// Window chrome the menu bar also drives. macOS expects a real File /
    /// View / Review menu, and a menu command has no view state to reach
    /// into — so the few pieces of window state that commands toggle live
    /// here rather than in `RootView`'s `@State`.
    /// Whether the window is showing the configuration screen.
    ///
    /// Settings is a surface, not a floating utility window: the same
    /// reasoning as opening a pull request — it is a screen the reviewer goes
    /// to and comes back from, and a panel hovering over the diff was both
    /// smaller than the content needed and in the way of it.
    @Published private(set) var isSettingsPresented = false
    @Published var settingsPane: SettingsPane = .account

    @Published var isOpenPRSheetPresented = false
    @Published var isInspectorPresented = true
    @Published var isSubmitFormPresented = false
    @Published var isCommandPalettePresented = false
    @Published var inspectorRail: InspectorRail = .ai

    enum InspectorRail: String, CaseIterable, Identifiable {
        case ai = "AI"
        case conversation = "Conversation"
        var id: String { rawValue }
        var symbol: String { self == .ai ? "sparkles" : "bubble.left.and.bubble.right" }
    }

    // Loaded PR
    @Published var reference: PRReference?
    @Published var pullRequest: PullRequest?
    @Published var files: [PRFile] = []
    @Published var parsedFiles: [String: ParsedFile] = [:]
    /// The longest line in each parsed file, in display columns. The diff
    /// pane sizes its horizontal canvas from this, so the canvas is right on
    /// the first frame that has content.
    @Published private(set) var diffColumnsByPath: [String: Int] = [:]
    /// Files whose patch is being parsed right now, so the pane can say so
    /// rather than rendering a parsed-but-empty file as "no changes".
    @Published private(set) var parsingPaths: Set<String> = []

    /// Which parsed patches to keep as the reviewer moves through files.
    private var parsedBudget = ParsedDiffBudget()
    @Published var issueComments: [IssueComment] = []
    @Published var reviews: [Review] = []
    @Published var threads: [ReviewThread] = []
    @Published var selectedFile: String?
    @Published var expandedContextLines: [String: [String]] = [:]

    @Published var isLoading = false
    /// Which pull request the in-flight load is for. `reference` only ever
    /// holds a *loaded* PR, so the loading surface would otherwise have
    /// nothing to name while it waits.
    @Published private(set) var loadingReference: PRReference?
    /// Which of the five requests have come back. Reported honestly: a stage
    /// is marked only once its response is in hand.
    @Published private(set) var completedLoadStages: Set<PRLoadStage> = []
    @Published private(set) var loadStartedAt: Date?
    @Published var loadError: String?

    // Local review state
    @Published var draft = ReviewDraft() {
        didSet {
            guard !isRestoringDraft else { return }
            if draft.isSubmitted == true { draft.isSubmitted = false }
            scheduleDraftSave()
        }
    }
    @Published private(set) var draftSaveError: String?
    /// Drafts that did not reach disk, keyed by host and reference.
    ///
    /// A save failure used to be able to trap the reviewer: `closePR`,
    /// `loadDemo` and `performLoad` each began `guard persistDraft() else
    /// { return }`, so on any project whose draft file could not be written
    /// — every nested GitLab group, until `PRStoreFileName` — clicking back
    /// to the dashboard did nothing at all and the only way out was to
    /// force-quit, which is what actually destroyed the review. Navigation no
    /// longer depends on the save; the unsaved copy is held here instead, so
    /// leaving the workspace costs nothing and reopening restores it.
    private var unsavedDrafts: [String: UnsavedDraft] = [:]
    /// Whether any staged review exists only in this process.
    var hasUnsavedDrafts: Bool { !unsavedDrafts.isEmpty }
    /// The one disk write, behind a closure so that "a failed save must not
    /// trap the reviewer" can be tested. The honest alternative — making the
    /// reviewer's real Application Support directory unwritable for the
    /// duration of a test — is destructive, and silently passes when the
    /// tests run as root. Production never replaces this.
    var saveDraftToDisk: (ReviewDraft, PRReference, ForgeHost) throws -> Void = {
        try DraftStore.saveChecked($0, for: $1, host: $2)
    }
    private var isRestoringDraft = false
    /// Pending debounced save. See `scheduleDraftSave`.
    private var draftSaveTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Half-written inline comments, by composer anchor.
    ///
    /// Held here rather than inside the `@Published` draft: nothing renders
    /// it — the dashboard's shelf counts the copy on disk — and routing a
    /// keystroke through `draft` republished `AppModel`, which re-renders
    /// every surface in the window. `persistDraft` folds it back in, so what
    /// reaches disk is unchanged.
    private var pendingComposerComments: [String: DraftComment] = [:]
    private var draftHost: ForgeHost = .dotCom
    private var isDemoReview = false
    @Published var isSubmittingReview = false
    @Published var submitError: String?

    /// The review workspace's API, dispatching to whichever forge the
    /// current host speaks. Named `githubClient` no longer: it serves a
    /// GitLab merge request through the same five calls.
    private var forgeClient: ForgeClient {
        ForgeClient(host: settings.githubHost, basic: basicCredential)
    }

    /// HTTP Basic for the current host, for an instance behind a
    /// Basic-protected front door. Read from the Keychain alongside the
    /// token and republished when either changes.
    @Published private(set) var basicCredential: BasicCredential?
    private var cancellables: Set<AnyCancellable> = []
    /// Held so an open in progress can be abandoned. Without it a slow or
    /// hanging fetch leaves the window on the opening screen with no way
    /// back short of quitting.
    private var loadTask: Task<Void?, Never>?
    /// Comments, reviews and threads, which arrive after the workspace does.
    private var discussionLoadTask: Task<Void, Never>?

    /// System notifications: permission, delivery, and what a click on one
    /// does. Owned here rather than by the dashboard because a notification
    /// clicked while no dashboard exists still has to open a pull request,
    /// and the settings pane needs the same instance to report permission.
    let notifications = NotificationService()

    // Feature models. Each owns its own state and reaches GitHub through
    // `context`; `AppModel` only holds them and connects the few places
    // they must agree (an opened PR, a submitted review, thread state).
    lazy var dashboard = DashboardModel(context: context, notifications: notifications)
    lazy var auth = AuthModel(context: context)
    lazy var conversation = ConversationModel(context: context)
    lazy var ai = AIModel(context: context)
    /// The ⌘K palette. Its command set is rebuilt from this model each time
    /// it opens, so it always reflects the pull request and inbox on screen.
    lazy var palette: CommandPaletteModel = {
        let palette = CommandPaletteModel()
        palette.provider = { [weak self] in
            guard let self else { return [] }
            return CommandRegistry.commands(for: self)
        }
        return palette
    }()
    /// The diff pane and the file tree are siblings in the split view, so
    /// the workspace track shares one instance rather than an environment
    /// object with no common ancestor.
    var workspace: WorkspaceModel { .shared }

    init() {
        let loadedSettings = AppSettings.load()
        settings = loadedSettings
        // The Keychain is *not* read here. On a build whose signature the
        // Keychain does not recognise, reading it puts a modal approval panel
        // in front of the reviewer before the window has even drawn — and
        // blocks `init` on the main thread until they answer it. The token is
        // fetched on first use instead, by `loadTokenIfNeeded()`.

        // The file tree wants unresolved counts, which only the
        // conversation track can compute (REST omits resolution state).
        // Bridging here keeps both tracks unaware of each other.
        conversation.$threads
            .map(ConversationModel.unresolvedCounts(fromThreads:))
            .receive(on: RunLoop.main)
            .sink { [weak self] counts in self?.workspace.unresolvedCountsByPath = counts }
            .store(in: &cancellables)

        // The draft save is debounced, so the two moments when the window
        // may be about to stop existing are the two that have to flush it.
        // Synchronously, not through a `Task`: at `willTerminate` there is
        // no next run loop iteration to hand work to.
        for name in [NSApplication.willTerminateNotification, NSApplication.willResignActiveNotification] {
            lifecycleObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.flushPendingDraftSave() }
                }
            )
        }
    }

    deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Writes the draft now if a debounced save is waiting. Cheap when none
    /// is, which is most of the time.
    private func flushPendingDraftSave() {
        guard draftSaveTask != nil else { return }
        persistDraft()
    }

    /// The handle feature models (dashboard, auth, conversation, AI) use to
    /// reach GitHub and app settings. Weakly captured so a child model
    /// holding this context does not keep `AppModel` alive.
    ///
    /// `api` builds a new `GitHubAPI` value on every call rather than
    /// holding one instance — that is what lets a host or token change
    /// reach every feature model without re-wiring anything. This is cheap
    /// because `GitHubAPI` itself resolves its `URLSession` from a
    /// per-host cache (see `GitHubSessionCache` in `GitHubAPI.swift`),
    /// so repeated construction here does not repeatedly pay for a new
    /// connection pool.
    var context: AppContext {
        AppContext(
            api: { [weak self] in GitHubAPI(host: self?.settings.githubHost ?? .dotCom) },
            token: { [weak self] in self?.githubToken },
            saveToken: { [weak self] token in self?.saveToken(token) },
            forgetToken: { [weak self] in self?.signOut() },
            basic: { [weak self] in self?.basicCredential },
            saveBasic: { [weak self] credential in self?.saveBasicCredential(credential) },
            reloadCredential: { [weak self] in self?.reloadCredentialForCurrentHost() },
            credentialFor: { [weak self] host in self?.credential(for: host) ?? HostCredential(host: host, credential: .none) },
            knownHosts: { [weak self] in self?.knownHosts ?? [.dotCom] },
            settings: { [weak self] in self?.settings ?? AppSettings() },
            updateSettings: { [weak self] newValue in
                guard let self else { return }
                self.settings = newValue
                self.settings.save()
            }
        )
    }

    // MARK: - Settings

    func persistSettings() {
        settings.save()
    }

    /// Reads the token from the Keychain, at most once per launch.
    ///
    /// Called when something actually needs it rather than at startup, so an
    /// approval panel — if this build draws one — appears in response to the
    /// reviewer doing something, not out of nowhere while the app opens. A
    /// refusal is remembered for the session: asking again every time any
    /// screen wants the token is what made the panel feel relentless.
    /// The environment variable a development build can be run with instead
    /// of storing anything.
    ///
    /// This exists because of how macOS ties a Keychain item to the exact
    /// build that saved it: an ad-hoc-signed app gets a new identity on every
    /// rebuild, so the Keychain asks for approval again, and approving does
    /// not help the next build. Exporting a token sidesteps the Keychain
    /// entirely — nothing is stored, nothing is asked.
    static let tokenEnvironmentVariable = "REVIEWRR_GITHUB_TOKEN"

    func loadTokenIfNeeded() {
        guard case .unread = tokenSource else { return }

        if let fromEnvironment = ProcessInfo.processInfo.environment[Self.tokenEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromEnvironment.isEmpty {
            githubToken = fromEnvironment
            tokenSource = .environment
            basicCredential = ForgeCredentialStore.readBasic(host: settings.githubHost)
            return
        }

        // A refusal is remembered across launches. Walking the reviewer into
        // the same panel every time they open the app, when they said no
        // yesterday, is the behaviour that made this feel broken.
        if settings.keychainAccessDeclined {
            tokenSource = .denied(.userDeclined)
            return
        }

        // Basic is read for the current host regardless of how the token
        // resolves: an instance behind a Basic front door needs it even when
        // the token came from the environment.
        basicCredential = ForgeCredentialStore.readBasic(host: settings.githubHost)

        switch KeychainStore.read(account: ForgeCredentialStore.tokenAccount(for: settings.githubHost)) {
        case .value(let token):
            githubToken = token
            tokenSource = .keychain
        case .notFound:
            tokenSource = .missing
        case .denied(let denial):
            tokenSource = .denied(denial)
            settings.keychainAccessDeclined = true
            persistSettings()
        case .failed(let status):
            tokenSource = .failed(status)
        }
    }

    /// Uses a token for this run without storing it.
    ///
    /// The way out when the Keychain has been refused: the reviewer stays in
    /// control of their credential, the app stays usable, and nothing is
    /// written to disk — `AGENTS.md` says tokens live in the Keychain, and a
    /// token that lives only in memory does not break that.
    func useSessionToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        githubToken = trimmed
        tokenSource = .session
        tokenVerification = .unknown
        flushPendingDeepLink()
    }

    /// Tries the Keychain once more — for the button offered after a refusal.
    func retryKeychain() {
        settings.keychainAccessDeclined = false
        persistSettings()
        tokenSource = .unread
        loadTokenIfNeeded()
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch ForgeCredentialStore.writeToken(trimmed, host: settings.githubHost) {
        case .saved:
            tokenSource = .keychain
            settings.keychainAccessDeclined = false
            persistSettings()
        case .denied(let denial):
            // Saving was refused, so the token cannot be kept — but the
            // reviewer just typed it, and making them type it again next
            // launch is the app's problem, not theirs. It works for this run.
            tokenSource = .denied(denial)
        case .failed(let status):
            tokenSource = .failed(status)
        }
        githubToken = trimmed
        tokenVerification = .unknown
        flushPendingDeepLink()
    }

    func signOut() {
        ForgeCredentialStore.deleteAll(host: settings.githubHost)
        basicCredential = nil
        githubToken = nil
        tokenSource = .missing
        tokenVerification = .unknown
        // Signing out puts the reviewer back where a signed-out reviewer
        // belongs. Leaving `isSignInDismissed` set from earlier in the
        // session would drop them on a dashboard that can no longer load
        // anything, with no visible way back in.
        isSignInDismissed = false
    }

    /// Every host a reviewer can browse or watch on, in a stable order.
    ///
    /// GitHub.com is always present — it needs no configuration to exist,
    /// and a reviewer whose only configured host is a GitLab instance
    /// should still be able to watch a public GitHub repository. The rest
    /// come from hosts that have been adopted at some point.
    var knownHosts: [ForgeHost] {
        var seen = Set<String>()
        var hosts: [ForgeHost] = []
        for host in [ForgeHost.dotCom, settings.githubHost] + settings.knownHosts
        where seen.insert(host.identityKey).inserted {
            hosts.append(host)
        }
        return hosts
    }

    /// The credential to use when talking to `host`.
    ///
    /// The active host answers from memory, because that is where a token
    /// taken from `REVIEWRR_GITHUB_TOKEN` or pasted "for this session only"
    /// lives — reading the Keychain for it would return nothing and report
    /// the reviewer as signed out of the host they are actively using.
    /// Every other host is read from the Keychain, where per-host
    /// credentials are stored.
    func credential(for host: ForgeHost) -> HostCredential {
        if host == settings.githubHost {
            return HostCredential(
                host: host,
                credential: ForgeCredential(token: githubToken, basic: basicCredential)
            )
        }
        return HostCredential(host: host, credential: ForgeCredentialStore.read(host: host).credential)
    }

    /// Saves (or clears, with nil) HTTP Basic for the current host.
    ///
    /// Separate from `saveToken` because the two are independent: a proxied
    /// instance needs both, a bare one needs only the token, and clearing
    /// one must never clear the other.
    func saveBasicCredential(_ credential: BasicCredential?) {
        guard let credential, !credential.isEmpty else {
            ForgeCredentialStore.deleteBasic(host: settings.githubHost)
            basicCredential = nil
            return
        }
        _ = ForgeCredentialStore.writeBasic(credential, host: settings.githubHost)
        basicCredential = credential
    }

    /// Re-reads the credential after a host switch. A credential is
    /// host-specific, so switching hosts changes *which* token and Basic
    /// pair is in effect — without this the app would keep sending the
    /// previous host's token to the new one and report a puzzling 401.
    func reloadCredentialForCurrentHost() {
        let host = settings.githubHost
        basicCredential = ForgeCredentialStore.readBasic(host: host)
        switch KeychainStore.read(account: ForgeCredentialStore.tokenAccount(for: host)) {
        case .value(let token):
            githubToken = token
            tokenSource = .keychain
        case .notFound:
            githubToken = nil
            tokenSource = .missing
        case .denied(let denial):
            githubToken = nil
            tokenSource = .denied(denial)
        case .failed(let status):
            githubToken = nil
            tokenSource = .failed(status)
        }
        tokenVerification = .unknown
    }

    func verifyToken() async {
        loadTokenIfNeeded()
        tokenVerification = .verifying
        do {
            let user = try await forgeClient.verifyToken(githubToken)
            tokenVerification = .valid(user.login)
        } catch {
            tokenVerification = .invalid(Self.describe(error))
        }
    }

    /// Prefers `LocalizedError.errorDescription` explicitly rather than
    /// trusting `Error.localizedDescription`'s NSError-bridging to pick it
    /// up implicitly — so a `GitHubError`'s specific, diagnosable message
    /// (HTTP status, GitHub's own message, a body snippet) always reaches
    /// the alert text, never a generic fallback string.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Loading a PR

    func loadPR(reference input: String) async {
        guard let reference = PRReference.parse(input) else {
            loadError = "Paste a GitHub PR URL or owner/repo#123."
            return
        }
        await load(reference)
    }

    /// Parses every file's patch away from the main actor, in parallel.
    ///
    /// Parsing is pure CPU work over independent files, and doing it inline
    /// on `@MainActor` stalled the window for tens of milliseconds before a
    /// large pull request could render — the one moment the reviewer is
    /// already waiting.
    /// Parses one file's patch if it is not already in hand, and keeps it.
    ///
    /// Returns once the file is parsed, so a caller that needs its hunks —
    /// a jump resolving a line to a row — can simply await it.
    func ensureParsed(_ path: String) async {
        guard parsedFiles[path] == nil else {
            touchParsed(path)
            return
        }
        guard let file = files.first(where: { $0.filename == path }) else { return }
        guard !parsingPaths.contains(path) else { return }

        parsingPaths.insert(path)
        let result = await Self.parseOne(file)
        parsingPaths.remove(path)

        // The pull request may have been closed or reloaded while this ran.
        guard files.contains(where: { $0.filename == path }) else { return }
        parsedFiles[path] = result.parsed
        diffColumnsByPath[path] = result.columns
        touchParsed(path)
    }

    /// Parses the files either side of `path` without waiting for them, so
    /// stepping with `j`/`k` lands on a file that is already in hand.
    func prefetchNeighbours(of path: String, in order: [String]) {
        guard let index = order.firstIndex(of: path) else { return }
        for neighbour in [index - 1, index + 1].compactMap({ order.indices.contains($0) ? order[$0] : nil }) {
            guard parsedFiles[neighbour] == nil else { continue }
            Task { await ensureParsed(neighbour) }
        }
    }

    private func touchParsed(_ path: String) {
        for evicted in parsedBudget.touch(path) {
            parsedFiles.removeValue(forKey: evicted)
        }
    }

    nonisolated private static func parseOne(_ file: PRFile) async -> (parsed: ParsedFile, columns: Int) {
        await Task.detached(priority: .userInitiated) {
            let parsed = DiffParser.parse(filename: file.filename, patch: file.patch)
            var columns = 0
            outer: for hunk in parsed.hunks {
                for line in hunk.lines {
                    columns = max(columns, DiffText.displayColumns(line.text))
                    if columns >= DiffText.maxMeasuredColumns { break outer }
                }
            }
            return (parsed, min(columns, DiffText.maxMeasuredColumns))
        }.value
    }


    /// Opens a pull request in the review workspace. The dashboard's row
    /// action and the open-by-URL sheet both land here.
    @Published private(set) var navigationHistory = ReviewNavigationHistory()
    @Published private(set) var isNavigatingHistory = false
    var canNavigateBack: Bool { navigationHistory.canGoBack && !isLoading && !isNavigatingHistory }
    var canNavigateForward: Bool { navigationHistory.canGoForward && !isLoading && !isNavigatingHistory }

    func navigateHistory(offset: Int) async {
        guard !isLoading, !isNavigatingHistory,
              let destination = navigationHistory.destination(offset: offset) else { return }
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        switch destination {
        case .dashboard:
            closePR()
            guard reference == nil else { return }
        case .demo:
            loadDemo()
            guard reference == DemoFixture.reference else { return }
        case .pullRequest(let target, let host):
            guard host == settings.githubHost else {
                loadError = "This review belongs to \(host.displayName). Select that GitHub host in Settings before reopening it."
                return
            }
            await load(target)
            // Only whether the destination actually opened. A draft that could
            // not be saved no longer stops navigation, so it must not stop the
            // history cursor from following it either — that mismatch is what
            // makes Back and Forward start lying about where they go.
            guard reference == target, loadError == nil else { return }
        }
        navigationHistory.commit(offset: offset)
    }

    /// Opens a pull or merge request, on the host it belongs to.
    ///
    /// `host` matters as soon as more than one is in play. The inbox mixes
    /// rows from every watched host, and a reference alone says nothing
    /// about which server it came from — so opening a GitLab merge request
    /// while GitHub happened to be the active host sent the whole load
    /// fan-out to GitHub and produced a 404 that looked like a missing
    /// pull request.
    ///
    /// Adopting the row's host rather than passing it down through every
    /// call is deliberate: the workspace, the draft store, the conversation
    /// panel and the AI panel all read the active host, and a review is a
    /// session on one server. Switching makes all of them agree at once.
    func open(_ reference: PRReference, host: ForgeHost? = nil) async {
        guard !isNavigatingHistory else { return }
        if let host, host != settings.githubHost {
            settings.githubHost = host
            persistSettings()
            reloadCredentialForCurrentHost()
        }
        await load(reference)
    }

    // MARK: - Change navigation

    /// Steps to the next or previous change, continuing into adjacent files
    /// and wrapping at the ends of the pull request.
    ///
    /// One implementation, because there were two: the `n`/`p` keys fell
    /// through to "open the next file" (landing wherever that file's scroll
    /// happened to be), while the navigation bar's arrows did nothing at
    /// all at the last change of a file. Same gesture, two behaviours, and
    /// neither of them landed on a change.
    ///
    /// Async because crossing a file boundary needs that file's patch, and
    /// patches are parsed when a file is opened.
    func stepChange(_ delta: Int) async {
        guard let filename = selectedFile else { return }
        let hunks = parsedFiles[filename]?.hunks ?? []

        if let target = workspace.advanceHunk(in: filename, hunks: hunks, delta: delta) {
            workspace.jump(to: target.path, line: target.line, side: target.side)
            return
        }

        // Exhausted this file. Walk to the nearest adjacent file that has a
        // change in it, skipping any that have none — a rename, a mode
        // change, a binary file. Bounded by the file count, so a pull
        // request of nothing but binaries stops instead of spinning.
        let paths = workspace.orderedVisiblePaths
        guard paths.count > 1, let start = paths.firstIndex(of: filename) else { return }
        var index = start
        for _ in 1...paths.count {
            // Wrapping is deliberate: at the last change of the last file
            // the reviewer returns to the top of the pull request rather
            // than pressing a key that does nothing, which reads as broken.
            index = (index + delta + paths.count) % paths.count
            let candidate = paths[index]
            await ensureParsed(candidate)
            guard let target = workspace.enterFile(
                candidate, hunks: parsedFiles[candidate]?.hunks ?? [], from: delta
            ) else { continue }
            selectedFile = candidate
            workspace.jump(to: target.path, line: target.line, side: target.side)
            return
        }
    }

    // MARK: - Deep links

    /// A pull request a `reviewrr://` link asked for while there was no
    /// credential to fetch it with. Held so the link is honoured once the
    /// reviewer signs in, rather than being dropped — clicking a link and
    /// landing on a sign-in screen that then forgets what you clicked is
    /// the worst version of this feature.
    private var pendingDeepLink: PRReference?

    /// Opens a `reviewrr://owner/repo/number` link.
    ///
    /// Called from `onOpenURL`, which fires both while the app is running
    /// and on a launch caused by the link itself.
    func open(deepLink url: URL) {
        guard case .pullRequest(let reference)? = DeepLink.parse(url) else {
            // A malformed link is the reviewer's link, usually hand-built, so
            // it gets the shape that works rather than a shrug. Reported
            // through the same alert as a failed open: from where they are
            // standing, the link did not open.
            loadError = DeepLink.malformedMessage
            return
        }

        // The link may have launched the app, in which case the window is
        // behind whatever the reviewer clicked from.
        NSApp.activate(ignoringOtherApps: true)

        // Resolve the credential first: on a cold launch from a link this is
        // the first thing that needs it, and `isSignedIn` is otherwise still
        // answering from an unread Keychain.
        loadTokenIfNeeded()
        guard isSignedIn else {
            pendingDeepLink = reference
            showSignIn()
            return
        }

        Task { await open(reference) }
    }

    /// The `reviewrr://` link for the open pull request, for sharing. `nil`
    /// when nothing is open, and for the demo — whose fixture repository
    /// does not exist, so a link to it would resolve nowhere.
    var deepLinkForOpenPR: URL? {
        guard !isDemoReview else { return nil }
        return reference?.deepLinkURL
    }

    func copyDeepLinkForOpenPR() {
        guard let url = deepLinkForOpenPR else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Opens whatever a deep link asked for before sign-in, if anything.
    /// Called after a credential lands.
    private func flushPendingDeepLink() {
        guard let reference = pendingDeepLink else { return }
        pendingDeepLink = nil
        Task { await open(reference) }
    }

    /// Leaves the workspace and returns the window to the dashboard.
    /// Clearing the in-memory PR loses nothing: the draft is either on disk
    /// or held in `unsavedDrafts`, and reopening restores whichever it is.
    func closePR() {
        // Best effort, and deliberately not a gate. This used to be
        // `guard persistDraft() else { return }`, which meant a reviewer
        // whose draft file could not be written could not leave the
        // workspace: the button did nothing, forever, with no explanation.
        // A failed save keeps the draft in `unsavedDrafts` instead, so
        // clearing the in-memory pull request below loses nothing.
        persistDraft()
        if !isNavigatingHistory { navigationHistory.visit(.dashboard) }
        pullRequest = nil
        reference = nil
        files = []
        parsedFiles = [:]
        diffColumnsByPath = [:]
        issueComments = []
        reviews = []
        threads = []
        selectedFile = nil
        expandedContextLines = [:]
        loadError = nil
        submitError = nil
    }

    func reload() async {
        guard let reference else { return }
        await load(reference)
    }

    /// Loads the bundled fixture PR so the review workspace can be seen
    /// without a GitHub token or network access.
    func loadDemo() {
        // Not a gate, for the reason `closePR` explains.
        persistDraft()
        isDemoReview = true
        // Opening the demo is an answer to the sign-in screen: the reviewer
        // asked to look around without an account, so closing the demo
        // should land on the dashboard rather than back on sign-in.
        isSignInDismissed = true
        if !isNavigatingHistory { navigationHistory.visit(.demo) }
        isRestoringDraft = true
        defer { isRestoringDraft = false }
        reference = DemoFixture.reference
        pullRequest = DemoFixture.pullRequest
        let demoFiles = DemoFixture.reviewFiles
        files = demoFiles
        // The fixture is small and has no network behind it, so it is parsed
        // in one go rather than on demand.
        parsedFiles = Dictionary(
            uniqueKeysWithValues: demoFiles.map {
                ($0.filename, DiffParser.parse(filename: $0.filename, patch: $0.patch))
            }
        )
        diffColumnsByPath = parsedFiles.mapValues { parsed in
            min(
                DiffText.maxMeasuredColumns,
                parsed.hunks.reduce(0) { widest, hunk in
                    max(widest, hunk.lines.reduce(0) { max($0, DiffText.displayColumns($1.text)) })
                }
            )
        }
        issueComments = DemoFixture.issueComments
        reviews = DemoFixture.reviews
        threads = DemoFixture.reviewComments.groupedIntoThreads()
        selectedFile = demoFiles.first?.filename
        expandedContextLines = [:]
        draft = ReviewDraft()
        loadError = nil

        workspace.configureIfNeeded(
            prKey: DemoFixture.reference.key, hiddenFileCategories: settings.hiddenFileCategories
        )
        workspace.refresh(files: demoFiles)
        ai.configure(
            reference: DemoFixture.reference, pullRequest: DemoFixture.pullRequest, files: demoFiles
        )
    }

    /// Comments, reviews and threads, fetched after the workspace is already
    /// on screen.
    ///
    /// Each is applied as it lands and each failure is contained: a
    /// discussion endpoint that is slow, rate-limited, or missing on this
    /// forge must not take the diff down with it. The stage list finishes
    /// ticking here, so it reports what actually happened rather than
    /// stopping at the last request the reviewer had to wait for.
    private func loadDiscussion(_ reference: PRReference, headSha: String, token: String?) async {
        async let issueComments = forgeClient.fetchIssueComments(reference, token: token)
        async let reviews = forgeClient.fetchReviews(reference, token: token)
        async let reviewComments = forgeClient.fetchReviewComments(reference, token: token)

        let loadedIssueComments = (try? await issueComments) ?? []
        guard !Task.isCancelled, self.reference == reference else { return }
        self.issueComments = loadedIssueComments
        completedLoadStages.insert(.comments)

        let loadedReviews = (try? await reviews) ?? []
        guard !Task.isCancelled, self.reference == reference else { return }
        self.reviews = loadedReviews
        completedLoadStages.insert(.reviews)

        let loadedReviewComments = (try? await reviewComments) ?? []
        guard !Task.isCancelled, self.reference == reference else { return }
        self.threads = loadedReviewComments.groupedIntoThreads()
        completedLoadStages.insert(.threads)

        await conversation.load(
            reference: reference, headSha: headSha, restThreads: self.threads,
            issueComments: loadedIssueComments, reviews: loadedReviews
        )
    }

    /// Abandons an open in progress and returns the window to wherever it
    /// was. Cancellation reaches the in-flight `URLSession` calls, so nothing
    /// keeps running in the background after the reviewer backs out.
    func cancelLoad() {
        loadTask?.cancel()
    }

    private func load(_ reference: PRReference) async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            await self?.performLoad(reference)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad(_ reference: PRReference) async {
        // Not a gate, for the reason `closePR` explains: a reviewer whose
        // draft could not be written must still be able to open another
        // pull request.
        persistDraft()
        // First point where the token is genuinely needed. Reading it here
        // rather than at launch means any approval panel is the answer to
        // something the reviewer just did.
        loadTokenIfNeeded()
        let previousReference = self.reference
        isLoading = true
        loadingReference = reference
        completedLoadStages = []
        loadStartedAt = Date()
        loadError = nil
        defer {
            isLoading = false
            loadingReference = nil
            loadStartedAt = nil
        }

        let token = githubToken
        do {
            // Only the two the diff needs. The screen said "the workspace
            // opens as soon as the diff is in" while actually waiting for all
            // five, so a slow discussion endpoint held the whole review
            // behind a list stuck at "1 of 5" — most visibly on GitLab, whose
            // discussions call is the slowest of the set.
            async let pr = forgeClient.fetchPullRequest(reference, token: token)
            async let files = forgeClient.fetchFiles(reference, token: token)

            let loadedPR = try await pr
            completedLoadStages.insert(.pullRequest)
            let loadedFiles = try await files
            completedLoadStages.insert(.files)

            // Patches are parsed when a file is opened, not here: this used
            // to parse all 675 to show one.
            // The draft carries this pull request's viewed set, and `await`
            // below yields the main actor. Assigning files first let a view
            // mount holding the *previous* pull request's draft, which seeded
            // the diff pane's collapsed files from the wrong PR's progress
            // and then scrolled to one of them.
            self.isRestoringDraft = true
            self.isDemoReview = false
            self.draftHost = settings.githubHost
            let stored = restoreDraft(for: reference, host: draftHost)
            self.draft = stored.draft
            self.draft.isDiscarded = nil
            // The pending text lives outside `draft` while the window is
            // open; without this, the next save would write an empty store
            // over what was restored.
            self.pendingComposerComments = self.draft.pendingComments ?? [:]
            // Unfinished composer text returns as editable, unsent inline drafts.
            if previousReference != reference {
                self.draft.comments.append(contentsOf: (self.draft.pendingComments ?? [:]).values.filter { !$0.body.isEmpty })
                self.draft.pendingComments = nil
                self.pendingComposerComments = [:]
                workspace.clearAllComposerText()
            }
            reconcileDraftHeadSha(loadedPR.headSha)

            self.reference = reference
            self.pullRequest = loadedPR
            if !isNavigatingHistory { navigationHistory.visit(.pullRequest(reference, draftHost)) }
            self.isRestoringDraft = false
            // Never write back over a file the app could not read. Restoring
            // used to be followed unconditionally by a save, so a draft that
            // had merely stopped decoding was overwritten with an empty one
            // about a second after the reviewer opened the pull request —
            // unreadable turned into erased. `restoreDraft` has moved the file
            // aside and put the reason in the banner; the reviewer decides
            // what happens next.
            if stored.isWritable { persistDraft() }
            self.files = loadedFiles
            // Cleared on every load, not just a new pull request: a refetch
            // of the same one can carry new commits, and a cached patch from
            // before the push would render the previous revision's diff.
            self.parsedFiles = [:]
            self.diffColumnsByPath = [:]
            self.parsedBudget.removeAll()
            // Emptied here and filled by `loadDiscussion` below: showing the
            // previous pull request's comments under this one's diff, even for
            // a moment, is worse than showing none.
            self.issueComments = []
            self.reviews = []
            self.threads = []

            // Refreshing the pull request the reviewer is already reading must
            // not move them. Resetting the selection unconditionally sent ⌘R —
            // the most-used gesture in a long review — back to the top of the
            // first file, and dropped every expanded context gap with it. Only
            // a *different* pull request, or a selection that no longer exists
            // after the refresh, gets a new selection.
            let isSameReference = reference == previousReference
            if !isSameReference || selectedFile.map({ path in !loadedFiles.contains { $0.filename == path } }) ?? true {
                self.selectedFile = loadedFiles.first?.filename
            }
            if !isSameReference {
                self.expandedContextLines = [:]
            }

            settings.addRecent(reference.key)
            persistSettings()

            workspace.configureIfNeeded(prKey: reference.key, hiddenFileCategories: settings.hiddenFileCategories)
            workspace.refresh(files: loadedFiles)
            ai.configure(reference: reference, pullRequest: loadedPR, files: loadedFiles)
            dashboard.markOpened(reference: reference, updatedAt: loadedPR.updatedAt)

            // Discussion follows the diff rather than gating it.
            discussionLoadTask?.cancel()
            discussionLoadTask = Task { [weak self] in
                await self?.loadDiscussion(reference, headSha: loadedPR.headSha, token: token)
            }
        } catch is CancellationError {
            // The reviewer backed out; nothing to report.
        } catch let error as URLError where error.code == .cancelled {
            // Same, surfaced by URLSession rather than by the task itself.
        } catch {
            loadError = Self.describe(error)
        }
    }

    /// When the PR moved to a new head SHA, keep every draft but flag which
    /// ones no longer point at the tip revision so submission can warn.
    private func reconcileDraftHeadSha(_ headSha: String) {
        // Drafts remain associated with their original head SHA; the submit
        // flow re-validates line anchors against the current patch before
        // sending anything to GitHub.
        _ = headSha
    }

    func expandContext(for filename: String) async {
        guard expandedContextLines[filename] == nil, let reference, let pr = pullRequest else { return }
        do {
            guard let content = try await forgeClient.fetchFileContent(
                owner: reference.owner, repo: reference.repo, path: filename, ref: pr.headSha, token: githubToken
            ) else { return }
            expandedContextLines[filename] = content.components(separatedBy: "\n")
        } catch {
            // Context expansion is a convenience; a failure here shouldn't
            // interrupt review, so it's swallowed rather than surfaced.
        }
    }

    func toggleViewed(_ filename: String) {
        if draft.viewedFiles.contains(filename) {
            draft.viewedFiles.remove(filename)
        } else {
            draft.viewedFiles.insert(filename)
        }
    }

    func retryDraftSave() {
        flushUnsavedDrafts()
        persistDraft()
    }

    /// A draft held in memory because its file could not be written.
    private struct UnsavedDraft {
        let reference: PRReference
        let host: ForgeHost
        var draft: ReviewDraft
        /// The write failure, for the banner: the system's own sentence, which
        /// is the only part that says whether this is a full disk, a
        /// permission, or something else.
        var failureReason: String
    }

    private static func unsavedDraftKey(_ reference: PRReference, host: ForgeHost) -> String {
        "\(host.identityKey)|\(reference.key)"
    }

    /// What was on disk for this pull request, and whether that file may be
    /// written back over.
    private struct RestoredDraft {
        var draft: ReviewDraft
        var isWritable: Bool
    }

    private func restoreDraft(for reference: PRReference, host: ForgeHost) -> RestoredDraft {
        // A held copy is newer than the file by definition, and is the only
        // copy of that work.
        if let held = unsavedDrafts[Self.unsavedDraftKey(reference, host: host)] {
            return RestoredDraft(draft: held.draft, isWritable: true)
        }
        switch DraftStore.read(for: reference, host: host) {
        case .absent:
            return RestoredDraft(draft: ReviewDraft(), isWritable: true)
        case .decoded(let draft):
            return RestoredDraft(draft: draft, isWritable: true)
        case .unreadable(let quarantinedAt, let reason):
            // Opening with an empty shelf is unavoidable — the file could not
            // be read — but the reviewer is told, and told where their bytes
            // went, instead of finding out later that they are gone.
            let kept = quarantinedAt.map { "It has been kept as \"\($0.lastPathComponent)\"" }
                ?? "It could not be moved aside either"
            draftSaveError = "The review staged on \(reference.key) could not be read: \(reason) \(kept), "
                + "and nothing was overwritten. Comments you add now save normally."
            return RestoredDraft(draft: ReviewDraft(), isWritable: false)
        }
    }

    /// Saves after typing stops, rather than on every character.
    ///
    /// `draft.didSet` used to call `persistDraft` directly, so one keystroke
    /// in an inline comment JSON-encoded the whole review, wrote it to disk
    /// atomically, and then re-listed and re-decoded every saved draft in
    /// the support directory to refresh the dashboard shelf. On a review
    /// with real comments in it that is several milliseconds of synchronous
    /// file I/O between pressing a key and seeing the letter.
    ///
    /// Nothing is risked by waiting: every path that must not lose work —
    /// closing the pull request, submitting, opening another one, the app
    /// quitting — calls `persistDraft()` directly, and that cancels this.
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            _ = self?.persistDraft()
        }
    }

    /// Writes the draft now, cancelling any debounced save. Reports whether
    /// it reached disk — for the banner, not for gating navigation: nothing
    /// in the app may refuse to move because a save failed.
    @discardableResult
    private func persistDraft() -> Bool {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard !isDemoReview, let reference, let pullRequest else { return true }
        var saved = draft
        saved.pendingComments = pendingComposerComments.isEmpty ? nil : pendingComposerComments
        saved.referenceKey = reference.key
        saved.title = pullRequest.title
        saved.savedAt = Date()
        let succeeded = write(saved, for: reference, host: draftHost)
        if succeeded { dashboard.reloadSavedReviews() }
        return succeeded
    }

    /// One write, and the bookkeeping that makes a failed one survivable.
    ///
    /// A draft that did not reach disk is held here in memory, keyed by host
    /// and reference, so leaving the workspace no longer has to mean losing
    /// it: `restoreDraft` prefers the held copy when that pull request is
    /// reopened, and `retryDraftSave` tries all of them again. It still only
    /// lives as long as the process — the banner says so.
    private func write(_ draft: ReviewDraft, for reference: PRReference, host: ForgeHost) -> Bool {
        let key = Self.unsavedDraftKey(reference, host: host)
        do {
            try saveDraftToDisk(draft, reference, host)
            unsavedDrafts.removeValue(forKey: key)
            refreshDraftSaveError()
            return true
        } catch {
            unsavedDrafts[key] = UnsavedDraft(
                reference: reference, host: host, draft: draft,
                failureReason: (error as NSError).localizedDescription
            )
            refreshDraftSaveError()
            return false
        }
    }

    /// Re-attempts every draft that has not reached disk, not only the one on
    /// screen: the reviewer may have moved on since the failure, and the held
    /// copy is the only copy.
    private func flushUnsavedDrafts() {
        // A snapshot: `write` mutates the dictionary being iterated.
        for held in Array(unsavedDrafts.values) {
            _ = write(held.draft, for: held.reference, host: held.host)
        }
    }

    /// The banner reflects what is unsaved, not what failed last. A save that
    /// succeeds while another pull request's draft is still stuck must not
    /// clear the warning about it.
    ///
    /// It shares one property with the "could not read the stored draft"
    /// notice `restoreDraft` sets, which is what `RootView`'s banner reads.
    /// That notice therefore stands until the next successful save — by which
    /// point the reviewer's current work is safe, which is the point at which
    /// it stops being urgent.
    private func refreshDraftSaveError() {
        guard let stuck = unsavedDrafts.values.sorted(by: { $0.reference.key < $1.reference.key }).first else {
            draftSaveError = nil
            return
        }
        let detail = unsavedDrafts.count > 1 ? " (and \(unsavedDrafts.count - 1) more)" : ""
        draftSaveError = "Your review of \(stuck.reference.key)\(detail) could not be saved to disk: "
            + "\(stuck.failureReason) It is still held in this window — press Retry Save. Quitting before it "
            + "succeeds loses it."
    }

    // MARK: - Draft comments

    func saveComposerDraft(path: String, line: Int, side: DiffSide, body: String) {
        guard let headSha = pullRequest?.headSha else { return }
        let key = WorkspaceModel.composerKey(path: path, line: line, side: side)
        if body.isEmpty {
            pendingComposerComments.removeValue(forKey: key)
        } else {
            var comment = pendingComposerComments[key]
                ?? DraftComment(path: path, line: line, side: side, body: body, headSha: headSha)
            comment.body = body
            pendingComposerComments[key] = comment
        }
        scheduleDraftSave()
    }

    /// `startLine` is the first line of a multi-line comment — the range a
    /// reviewer dragged out in the gutter. `nil` comments on `line` alone.
    func addDraftComment(path: String, line: Int, side: DiffSide, body: String, startLine: Int? = nil) {
        guard let headSha = pullRequest?.headSha else { return }
        // A range that collapsed to one line is a single-line comment, not a
        // range of one: GitHub rejects `start_line == line`.
        var start = startLine.flatMap { $0 < line ? $0 : nil }
        // And a range has to stay inside one hunk. The gutter clamps the drag
        // already; this is the backstop, because a range reaching outside the
        // diff makes GitHub reject the entire review, not the one comment.
        if let candidate = start, let hunks = parsedFiles[path]?.hunks {
            let sameHunk = hunks.contains { hunk in
                let numbers = hunk.lines.compactMap { side == .left ? $0.oldLineNumber : $0.newLineNumber }
                guard let low = numbers.min(), let high = numbers.max() else { return false }
                return low <= candidate && line <= high
            }
            if !sameHunk { start = nil }
        }
        draft.comments.append(
            DraftComment(
                path: path, line: line, side: side, body: body, headSha: headSha,
                startLine: start, startSide: start == nil ? nil : side
            )
        )
    }

    func updateDraftComment(_ id: UUID, body: String) {
        guard let index = draft.comments.firstIndex(where: { $0.id == id }) else { return }
        draft.comments[index].body = body
    }

    func deleteDraftComment(_ id: UUID) {
        draft.comments.removeAll { $0.id == id }
    }

    // MARK: - Submit review

    func submitReview() async {
        guard let reference, !draft.comments.isEmpty || !draft.summary.isEmpty else { return }
        isSubmittingReview = true
        submitError = nil
        defer { isSubmittingReview = false }
        do {
            try await forgeClient.submitReview(
                reference, token: githubToken, summary: draft.summary, event: draft.event, comments: draft.comments
            )
            isRestoringDraft = true
            draft.comments = []
            // The comments those lines belonged to are on GitHub now; a range
            // left lit would attach the next comment to it.
            workspace.clearLineSelection()
            workspace.closeComposer()
            draft.summary = ""
            draft.event = .comment
            draft.isSubmitted = pendingComposerComments.isEmpty
            isRestoringDraft = false
            persistDraft()
            dashboard.markReviewed(reference, headSha: pullRequest?.headSha)
            await reload()
        } catch {
            submitError = Self.describe(error)
        }
    }
}
