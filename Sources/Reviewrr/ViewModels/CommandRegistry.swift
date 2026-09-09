import AppKit
import Foundation

/// Everything the ⌘K palette can do, assembled fresh each time it opens.
///
/// Rebuilding rather than caching is deliberate: half of these commands are
/// the *contents* of the app — the files in this pull request, the rows in
/// the inbox, the watched projects — and a stale list is worse than no list.
/// Building the whole set is a few hundred struct initializations.
///
/// The `shortcut:` labels are read from `Shortcut` rather than typed here.
/// Written out by hand they were a third, independent claim about the
/// keyboard — this palette printed "⌘↩" for Submit Review while the menu
/// bound it, the composers fought it, and the shortcuts sheet said something
/// else again.
@MainActor
enum CommandRegistry {
    static func commands(for model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        commands += navigation(model)
        commands += pullRequest(model)
        commands += files(model)
        commands += inbox(model)
        commands += projects(model)
        commands += ai(model)
        commands += view(model)
        commands += app(model)
        return commands
    }

    // MARK: - Go

    private static func navigation(_ model: AppModel) -> [PaletteCommand] {
        let hasPR = model.pullRequest != nil
        return [
            PaletteCommand(
                id: "go.dashboard", title: "Go to Dashboard",
                subtitle: hasPR ? "Leave this pull request" : nil,
                symbol: "square.grid.2x2", group: .go, shortcut: Shortcut.goToDashboard.display,
                keywords: ["home", "inbox", "back", "projects"],
                isEnabled: hasPR
            ) { model.closePR() },

            PaletteCommand(
                id: "go.openURL", title: "Open Pull Request by URL…",
                subtitle: "Paste a link or owner/repo#123",
                symbol: "link", group: .go, shortcut: Shortcut.openPullRequest.display,
                keywords: ["paste", "url", "link", "jump"]
            ) { model.isOpenPRSheetPresented = true },

            PaletteCommand(
                id: "go.settings", title: "Open Settings",
                symbol: "gearshape", group: .go, shortcut: Shortcut.settings.display,
                keywords: ["preferences", "token", "account", "provider", "config"]
            ) { model.openSettings() },

            PaletteCommand(
                id: "go.integrations", title: "Jira Issue Links",
                subtitle: model.settings.issueTracker.isUsable
                    ? model.settings.issueTracker.normalizedBaseURL?.host
                    : "Not configured",
                symbol: "link", group: .go,
                keywords: ["jira", "issue", "ticket", "atlassian", "browse", "tracker"]
            ) { model.openSettings(.integrations) },

            PaletteCommand(
                id: "go.notifications", title: "Notification Settings",
                subtitle: model.settings.notifications.enabled ? "On" : "Off",
                symbol: "bell.badge", group: .go,
                keywords: ["alert", "notify", "banner", "quiet", "hours", "permission", "sound"]
            ) { model.openSettings(.notifications) },

            PaletteCommand(
                id: "go.demo", title: "Open Demo Pull Request",
                subtitle: "Explore the workspace without a token",
                symbol: "sparkles.rectangle.stack", group: .go,
                keywords: ["sample", "example", "try", "offline"]
            ) { model.loadDemo() },
        ]
    }

    // MARK: - Pull request

    private static func pullRequest(_ model: AppModel) -> [PaletteCommand] {
        let pr = model.pullRequest
        let hasPR = pr != nil
        let hasDraft = !model.draft.comments.isEmpty || !model.draft.summary.isEmpty
        let viewedCount = model.draft.viewedFiles.count

        var commands: [PaletteCommand] = issues(model) + [
            PaletteCommand(
                id: "pr.refresh", title: "Refresh Pull Request",
                symbol: "arrow.clockwise", group: .pullRequest, shortcut: Shortcut.refresh.display,
                keywords: ["reload", "sync", "update"],
                isEnabled: hasPR
            ) { Task { await model.reload() } },

            PaletteCommand(
                id: "pr.submit", title: "Submit Review…",
                subtitle: hasDraft ? "\(model.draft.comments.count) draft comment(s)" : "Add a summary or a comment first",
                symbol: "paperplane", group: .pullRequest, shortcut: Shortcut.submitReview.display,
                keywords: ["approve", "request changes", "comment", "send", "publish"],
                isEnabled: hasPR && hasDraft
            ) { model.isSubmitFormPresented = true },

            PaletteCommand(
                id: "pr.openGitHub", title: "Open on GitHub",
                symbol: "safari", group: .pullRequest, shortcut: Shortcut.openOnHost.display,
                keywords: ["browser", "web", "safari"],
                isEnabled: hasPR
            ) {
                guard let url = pr.flatMap({ URL(string: $0.htmlUrl) }) else { return }
                NSWorkspace.shared.open(url)
            },

            PaletteCommand(
                id: "pr.copyDeepLink", title: "Copy Reviewrr Link",
                subtitle: model.deepLinkForOpenPR?.absoluteString,
                symbol: "link.badge.plus", group: .pullRequest, shortcut: Shortcut.copyDeepLink.display,
                keywords: ["deep link", "share", "url", "reviewrr://", "clipboard", "copy"],
                isEnabled: model.deepLinkForOpenPR != nil
            ) { model.copyDeepLinkForOpenPR() },

            PaletteCommand(
                id: "pr.copyLink", title: "Copy Pull Request Link",
                symbol: "doc.on.doc", group: .pullRequest,
                keywords: ["url", "share", "clipboard"],
                isEnabled: hasPR
            ) { copy(pr?.htmlUrl) },

            PaletteCommand(
                id: "pr.copyBranch", title: "Copy Branch Name",
                subtitle: pr?.headRef, symbol: "arrow.branch", group: .pullRequest,
                keywords: ["head", "checkout", "git", "clipboard"],
                isEnabled: hasPR
            ) { copy(pr?.headRef) },

            // Named for what it does and wired to the one implementation
            // `v` and ⇧⌘V share. It used to say "Mark Current File Viewed"
            // beside a chord that, pressed twice, un-marked the file the
            // reviewer had just finished.
            PaletteCommand(
                id: "pr.markViewed",
                title: isCurrentFileViewed(model) ? "Mark File Not Viewed" : "Mark File Viewed and Open Next",
                subtitle: model.selectedFile.map { ($0 as NSString).lastPathComponent },
                symbol: "checkmark.circle", group: .pullRequest, shortcut: Shortcut.markViewedMenu.display,
                keywords: ["seen", "read", "progress", "done", "next", "unread"],
                isEnabled: model.selectedFile != nil
            ) {
                guard let file = model.selectedFile else { return }
                model.markViewedAndAdvance(file)
            },

            PaletteCommand(
                id: "pr.markAllViewed", title: "Mark All Files Viewed",
                subtitle: hasPR ? "\(viewedCount) of \(model.files.count) already viewed" : nil,
                symbol: "checkmark.circle.fill", group: .pullRequest,
                keywords: ["everything", "progress", "complete"],
                isEnabled: hasPR && viewedCount < model.files.count
            ) {
                for file in model.files where !model.draft.viewedFiles.contains(file.filename) {
                    model.toggleViewed(file.filename)
                }
            },

            PaletteCommand(
                id: "pr.clearViewed", title: "Clear Viewed Files",
                subtitle: "Start this review over",
                symbol: "arrow.uturn.backward.circle", group: .pullRequest,
                keywords: ["reset", "unread", "progress"],
                isEnabled: viewedCount > 0
            ) {
                for file in model.draft.viewedFiles { model.toggleViewed(file) }
            },

            PaletteCommand(
                id: "pr.close", title: "Close Pull Request",
                subtitle: "Return to the dashboard; drafts are kept",
                symbol: "xmark.circle", group: .pullRequest, shortcut: Shortcut.closePullRequest.display,
                keywords: ["leave", "exit", "dismiss"],
                isEnabled: hasPR
            ) { model.closePR() },
        ]

        // Next/previous file need the same visible-and-filtered order the
        // sidebar shows, so they follow the tree rather than the raw list.
        let order = model.workspace.orderedVisiblePaths
        if hasPR, order.count > 1 {
            commands.append(
                PaletteCommand(
                    id: "pr.nextFile", title: "Next File",
                    symbol: "chevron.down", group: .pullRequest, shortcut: Shortcut.nextFile.display,
                    keywords: ["forward", "advance", "navigate"]
                ) {
                    guard let next = DiffNavigator.adjacentFile(to: model.selectedFile, in: order, delta: 1) else { return }
                    model.selectedFile = next
                    model.workspace.jump(to: next)
                }
            )
            commands.append(
                PaletteCommand(
                    id: "pr.previousFile", title: "Previous File",
                    symbol: "chevron.up", group: .pullRequest, shortcut: Shortcut.previousFile.display,
                    keywords: ["back", "navigate"]
                ) {
                    guard let previous = DiffNavigator.adjacentFile(to: model.selectedFile, in: order, delta: -1) else { return }
                    model.selectedFile = previous
                    model.workspace.jump(to: previous)
                }
            )
            commands.append(
                PaletteCommand(
                    id: "pr.nextUnviewed", title: "Next Unreviewed File",
                    subtitle: "Skip the files already marked viewed",
                    symbol: "arrow.forward.to.line", group: .pullRequest,
                    keywords: ["unviewed", "unread", "remaining", "todo"]
                ) {
                    guard let next = model.workspace.nextUnviewedPath(
                        after: model.selectedFile, viewedFiles: model.draft.viewedFiles
                    ) else { return }
                    model.selectedFile = next
                    model.workspace.jump(to: next)
                }
            )
        }
        return commands
    }

    // MARK: - Files in this pull request

    /// One command per issue this pull request mentions.
    ///
    /// The keys are already chips in the header, but a reviewer with the
    /// palette open and a hand on the keyboard should not have to go looking
    /// for them — and the palette is the only place that can search by key.
    private static func issues(_ model: AppModel) -> [PaletteCommand] {
        let tracker = model.settings.issueTracker
        guard tracker.isUsable, let pr = model.pullRequest else { return [] }
        let references = IssueKeyDetector(settings: tracker).keys(
            title: pr.title, body: pr.body, branch: pr.head.ref
        )
        return references.compactMap { reference in
            guard let url = tracker.url(for: reference.key) else { return nil }
            return PaletteCommand(
                id: "pr.issue.\(reference.key)",
                title: "Open \(reference.key) in Jira",
                subtitle: url.host,
                symbol: "arrow.up.forward.square", group: .pullRequest,
                keywords: ["jira", "issue", "ticket", reference.projectKey.lowercased(), reference.key.lowercased()]
            ) { NSWorkspace.shared.open(url) }
        }
    }

    private static func files(_ model: AppModel) -> [PaletteCommand] {
        // Bounded: a palette listing 900 files is a scrolling exercise, and
        // the ranking already surfaces what was typed.
        model.files.prefix(400).map { file in
            let viewed = model.draft.viewedFiles.contains(file.filename)
            let category = model.workspace.classifications[file.filename]?.category
            return PaletteCommand(
                id: "file.\(file.filename)",
                title: file.displayName,
                subtitle: file.directory == "/" ? nil : file.directory,
                symbol: viewed ? "checkmark.circle.fill" : (category?.symbolName ?? "doc.text"),
                group: .files,
                keywords: [file.filename, file.status.rawValue, category?.label ?? ""]
            ) {
                model.selectedFile = file.filename
                model.workspace.jump(to: file.filename)
            }
        }
    }

    // MARK: - Inbox

    private static func inbox(_ model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = model.dashboard.filteredRows.prefix(200).map { row in
            PaletteCommand(
                id: "inbox.\(row.reference.key)",
                title: row.title,
                subtitle: "\(row.owner)/\(row.repo) #\(row.number) · \(row.authorLogin)",
                symbol: "arrow.triangle.pull",
                group: .inbox,
                keywords: [row.repo, row.authorLogin, "#\(row.number)", row.state.rawValue]
            ) {
                let reference = row.reference
                Task { await model.open(reference) }
            }
        }

        commands.append(
            PaletteCommand(
                id: "inbox.clearFilters", title: "Clear Inbox Filters",
                subtitle: "Back to open pull requests",
                symbol: "line.3.horizontal.decrease.circle", group: .inbox,
                keywords: ["reset", "all", "show everything"],
                isEnabled: !model.dashboard.filter.isEmpty
            ) { model.dashboard.filter = InboxFilter() }
        )

        for state in InboxPRState.allCases {
            commands.append(
                PaletteCommand(
                    id: "inbox.state.\(state.rawValue)",
                    title: "Show \(state.label) Pull Requests",
                    symbol: "line.3.horizontal.decrease.circle", group: .inbox,
                    keywords: ["filter", state.rawValue]
                ) { model.dashboard.filter.states = [state] }
            )
        }

        commands.append(
            PaletteCommand(
                id: "inbox.reviewRequested", title: "Show Only Pull Requests Awaiting My Review",
                symbol: "person.crop.circle.badge.checkmark", group: .inbox,
                keywords: ["needs review", "requested", "mine", "assigned"]
            ) { model.dashboard.filter.reviewRequestedOfMeOnly = true }
        )

        return commands
    }

    // MARK: - Watched projects

    private static func projects(_ model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = [
            PaletteCommand(
                id: "projects.add", title: "Add Watched Project…",
                symbol: "plus.circle", group: .projects,
                keywords: ["watch", "repository", "repo", "follow", "new"]
            ) {
                model.closePR()
                model.dashboard.isAddProjectPresented = true
            },

            PaletteCommand(
                id: "projects.refreshAll", title: "Refresh All Projects",
                symbol: "arrow.clockwise.circle", group: .projects,
                keywords: ["sync", "poll", "update", "watchlist"],
                isEnabled: !model.dashboard.projects.isEmpty
            ) { Task { await model.dashboard.refreshAll(force: true) } },
        ]

        for project in model.dashboard.projects {
            commands.append(
                PaletteCommand(
                    id: "projects.refresh.\(project.key)",
                    title: "Refresh \(project.owner)/\(project.repo)",
                    symbol: "arrow.clockwise", group: .projects,
                    keywords: [project.owner, project.repo, "sync"]
                ) { Task { await model.dashboard.refresh(project) } }
            )
            commands.append(
                PaletteCommand(
                    id: "projects.mute.\(project.key)",
                    title: "\(project.isMuted ? "Unmute" : "Mute") \(project.owner)/\(project.repo)",
                    symbol: project.isMuted ? "bell" : "bell.slash",
                    group: .projects,
                    keywords: [project.owner, project.repo, "notifications", "quiet"]
                ) { model.dashboard.toggleMute(project) }
            )
        }
        return commands
    }

    // MARK: - AI

    private static func ai(_ model: AppModel) -> [PaletteCommand] {
        let hasPR = model.pullRequest != nil
        return [
            PaletteCommand(
                id: "ai.ask", title: "Ask AI About This Pull Request",
                symbol: "sparkles", group: .ai,
                keywords: ["question", "explain", "chat", "why", "help"],
                isEnabled: hasPR
            ) {
                model.isInspectorPresented = true
                model.inspectorRail = .ai
            },

            PaletteCommand(
                id: "ai.analyze", title: "Re-run Analysis",
                subtitle: "Fresh pass over the current revision",
                symbol: "arrow.clockwise.heart", group: .ai,
                keywords: ["findings", "review", "summary", "regenerate"],
                isEnabled: hasPR
            ) {
                model.isInspectorPresented = true
                model.inspectorRail = .ai
                Task { await model.ai.analyze(force: true) }
            },

            PaletteCommand(
                id: "ai.cancel", title: "Cancel AI Request",
                symbol: "stop.circle", group: .ai,
                keywords: ["stop", "abort", "halt"],
                isEnabled: hasPR
            ) { model.ai.cancel() },

            PaletteCommand(
                id: "ai.provider", title: "Change AI Provider or Model",
                subtitle: model.settings.aiProviderID,
                symbol: "cpu", group: .ai,
                keywords: ["anthropic", "openai", "openrouter", "ollama", "claude", "gpt", "key"]
            ) { model.openSettings(.ai) },
        ]
    }

    // MARK: - View

    private static func view(_ model: AppModel) -> [PaletteCommand] {
        let hasPR = model.pullRequest != nil
        let workspace = model.workspace
        var commands: [PaletteCommand] = [
            PaletteCommand(
                id: "view.togglePanel",
                title: model.isInspectorPresented ? "Hide Side Panel" : "Show Side Panel",
                symbol: "sidebar.trailing", group: .view, shortcut: Shortcut.toggleSidePanel.display,
                keywords: ["inspector", "rail", "right"],
                isEnabled: hasPR
            ) { model.isInspectorPresented.toggle() },

            PaletteCommand(
                id: "view.railConversation", title: "Show Conversation Panel",
                symbol: "bubble.left.and.bubble.right", group: .view,
                keywords: ["comments", "threads", "checks", "ci", "discussion"],
                isEnabled: hasPR
            ) {
                model.isInspectorPresented = true
                model.inspectorRail = .conversation
            },

            PaletteCommand(
                id: "view.split", title: "Use Split Diff",
                symbol: "rectangle.split.2x1", group: .view,
                keywords: ["side by side", "layout", "two column"],
                isEnabled: model.settings.diffLayout != .split
            ) {
                model.settings.diffLayout = .split
                model.persistSettings()
            },

            PaletteCommand(
                id: "view.unified", title: "Use Unified Diff",
                symbol: "list.bullet.rectangle", group: .view, shortcut: Shortcut.toggleLayout.display,
                keywords: ["single column", "layout", "inline"],
                isEnabled: model.settings.diffLayout != .unified
            ) {
                model.settings.diffLayout = .unified
                model.persistSettings()
            },

            PaletteCommand(
                id: "view.wordWrap",
                title: model.settings.wordWrap ? "Turn Off Word Wrap" : "Turn On Word Wrap",
                symbol: "text.alignleft", group: .view,
                keywords: ["wrap", "long lines", "truncate"]
            ) {
                model.settings.wordWrap.toggle()
                model.persistSettings()
            },

            PaletteCommand(
                id: "view.clearFileFilters", title: "Show All File Categories",
                subtitle: workspace.hiddenCategories.isEmpty ? "Nothing hidden" : "\(workspace.hiddenCategories.count) hidden",
                symbol: "eye", group: .view,
                keywords: ["unhide", "reset", "filters", "lockfile", "generated"],
                isEnabled: !workspace.hiddenCategories.isEmpty
            ) { workspace.hiddenCategories = [] },

            PaletteCommand(
                id: "view.shortcuts", title: "Keyboard Shortcuts",
                symbol: "keyboard", group: .view, shortcut: Shortcut.keyboardShortcuts.display,
                keywords: ["keys", "bindings", "help"],
                isEnabled: hasPR
            ) { workspace.showShortcuts = true },
        ]

        for category in FileCategory.allCases {
            let hidden = workspace.hiddenCategories.contains(category)
            commands.append(
                PaletteCommand(
                    id: "view.category.\(category.rawValue)",
                    title: "\(hidden ? "Show" : "Hide") \(category.label) Files",
                    symbol: hidden ? "eye" : "eye.slash", group: .view,
                    keywords: ["filter", category.rawValue, "triage", "noise"],
                    isEnabled: hasPR
                ) { workspace.toggleCategory(category) }
            )
        }
        return commands
    }

    // MARK: - App

    private static func app(_ model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = Appearance.allCases.map { appearance in
            PaletteCommand(
                id: "app.appearance.\(appearance.rawValue)",
                title: "Appearance: \(appearance.label)",
                symbol: appearance == .dark ? "moon" : (appearance == .light ? "sun.max" : "circle.lefthalf.filled"),
                group: .app,
                keywords: ["theme", "dark mode", "light mode", "colour", "color"],
                isEnabled: model.settings.appearance != appearance
            ) {
                model.settings.appearance = appearance
                model.persistSettings()
            }
        }

        commands.append(
            model.isSignedIn
                ? PaletteCommand(
                    id: "app.signOut",
                    title: "Sign Out of GitHub",
                    subtitle: "Forgets the credential on this Mac; does not revoke it",
                    symbol: "person.crop.circle.badge.xmark",
                    group: .app,
                    keywords: ["logout", "log out", "account", "token", "forget", "credential"]
                ) { model.auth.signOut() }
                : PaletteCommand(
                    id: "app.signIn",
                    title: "Sign In to GitHub",
                    subtitle: "Continue with GitHub, or paste a personal access token",
                    symbol: "person.crop.circle.badge.checkmark",
                    group: .app,
                    keywords: ["login", "log in", "auth", "oauth", "account", "token", "device"]
                ) { model.showSignIn() }
        )

        commands.append(
            PaletteCommand(
                id: "app.polling",
                title: model.settings.pollingEnabled ? "Pause Background Polling" : "Resume Background Polling",
                subtitle: "Only runs while Reviewrr is open",
                symbol: model.settings.pollingEnabled ? "pause.circle" : "play.circle",
                group: .app,
                keywords: ["sync", "refresh", "watchlist", "network"]
            ) {
                model.settings.pollingEnabled.toggle()
                model.persistSettings()
            }
        )

        commands.append(
            PaletteCommand(
                id: "app.notifications",
                title: model.settings.nativeNotificationsEnabled ? "Turn Off Native Notifications" : "Turn On Native Notifications",
                symbol: model.settings.nativeNotificationsEnabled ? "bell.slash" : "bell.badge",
                group: .app,
                keywords: ["alerts", "banner", "notify"]
            ) {
                model.settings.nativeNotificationsEnabled.toggle()
                model.persistSettings()
            }
        )

        return commands
    }

    // MARK: - Helpers

    private static func isCurrentFileViewed(_ model: AppModel) -> Bool {
        guard let file = model.selectedFile else { return false }
        return model.draft.viewedFiles.contains(file)
    }

    private static func copy(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }


}
