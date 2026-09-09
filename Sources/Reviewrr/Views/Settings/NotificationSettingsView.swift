import AppKit
import SwiftUI

/// When Reviewrr is allowed to interrupt you.
///
/// ## Why this is three cards and not twenty-five switches
///
/// The pane asked for a scope, eight update triggers, drafts, own pull
/// requests, a label allow-list, sound, grouping and a summary threshold —
/// to configure one bell. Almost nobody has an opinion about eight
/// triggers; they have one about how much they want to be interrupted, and
/// a preset is that opinion: pick "only what needs me" and the rest follow.
///
/// Everything that was here is still here, in Advanced, and touching any of
/// it reports the choice as Custom rather than leaving a preset name that no
/// longer describes the values behind it.
struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var isRequestingPermission = false
    @State private var didSendTest = false
    @State private var labelDraft = ""
    @State private var showsAdvanced = false

    private var preferences: Binding<NotificationPreferences> {
        Binding(
            get: { model.settings.notifications },
            set: { new in
                model.settings.notifications = new
                // The legacy top-level flag is the same switch — see
                // `AppSettings`. Kept in step here so an older reader and a
                // newer one never disagree about whether this is on.
                model.settings.nativeNotificationsEnabled = new.enabled
                model.persistSettings()
            }
        )
    }

    private var current: NotificationPreferences { model.settings.notifications }

    var body: some View {
        SettingsPage {
            heroCard
            if current.enabled {
                presetPicker
                quietHoursCard
                advancedDisclosure
            }
        }
        .task { await model.notifications.refreshPermission() }
    }

    private var permissionSymbol: String {
        switch model.notifications.permission {
        case .allowed: return "checkmark.circle.fill"
        case .allowedQuietly: return "bell.badge.slash"
        case .denied: return "xmark.circle.fill"
        case .notAsked: return "questionmark.circle"
        case .unavailable: return "minus.circle"
        }
    }

    private var permissionPalette: StatusPalette {
        switch model.notifications.permission {
        case .allowed: return .green
        case .allowedQuietly: return .orange
        case .denied: return .red
        case .notAsked, .unavailable: return .neutral
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - What

    private var whatSection: some View {
        Section {
            Toggle("A pull request is opened", isOn: preferences.notifyOnNewPullRequest)
                .help("Notifies when a pull request appears on a watched project that wasn't there at the last poll")

            Toggle("A pull request changes", isOn: preferences.notifyOnUpdate)
                .help("Notifies when one you already knew about moves — see the list below for which moves count")

            if model.settings.notifications.notifyOnUpdate {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PRUpdateTrigger.allCases) { trigger in
                        Toggle(isOn: triggerBinding(trigger)) {
                            Label(trigger.label, systemImage: trigger.systemImage)
                        }
                        .toggleStyle(.checkbox)
                        .help(help(for: trigger))
                    }
                }
                .padding(.leading, Theme.Space.l)
                .disabled(!model.settings.notifications.notifyOnUpdate)
            }
        } header: {
            Text("What to tell me about")
        } footer: {
            Text("“Changed” has to be derived from two polls, so it is spelled out rather than guessed at. A bumped timestamp on its own is never a notification — forges move it for a label edit or a board change.")
        }
        .disabled(!model.settings.notifications.enabled)
    }

    private func help(for trigger: PRUpdateTrigger) -> String {
        switch trigger {
        case .newCommits: return "The head commit moved: someone pushed to the branch"
        case .newComments: return "The comment count went up. Chatty pull requests notify often"
        case .reviewDecision: return "Someone approved it or asked for changes"
        case .checksChanged: return "CI went green, red, or back to pending. A flaky pipeline notifies often"
        case .readyForReview: return "A draft became a real pull request"
        case .merged: return "It landed"
        case .closed: return "It was closed without merging"
        case .reviewRequested: return "You were added as a reviewer to one you were already seeing"
        }
    }

    private func triggerBinding(_ trigger: PRUpdateTrigger) -> Binding<Bool> {
        Binding(
            get: { model.settings.notifications.updateTriggers.contains(trigger) },
            set: { isOn in
                var updated = model.settings.notifications
                if isOn { updated.updateTriggers.insert(trigger) } else { updated.updateTriggers.remove(trigger) }
                preferences.wrappedValue = updated
            }
        )
    }

    // MARK: - Which pull requests

    private var whichSection: some View {
        Section {
            Picker("Scope", selection: preferences.scope) {
                ForEach(NotificationScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.radioGroup)
            .help("Which pull requests are allowed to notify at all")

            Text(model.settings.notifications.scope.explanation)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include my own pull requests", isOn: preferences.includeOwnPullRequests)
                .help("Off by default: you know you opened it, and its checks and review activity are the loudest source there is")

            Toggle("Include drafts", isOn: preferences.includeDrafts)
                .help("A draft is work in progress — off by default")

            labelFilter
        } header: {
            Text("Which pull requests")
        }
        .disabled(!model.settings.notifications.enabled)
    }

    /// Optional label allow-list. Empty means "any label", which is stated
    /// rather than left to inference — an empty filter field that silently
    /// means "everything" reads like a broken filter.
    private var labelFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Only these labels") {
                HStack(spacing: 6) {
                    TextField("label", text: $labelDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit(addLabel)
                        .accessibilityLabel("Add a label filter")
                    Button("Add", action: addLabel)
                        .buttonStyle(.reviewrrGhost)
                        .disabled(labelDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Only notify about pull requests carrying this label")
                }
            }

            if model.settings.notifications.requiredLabels.isEmpty {
                Text("Any label. Add one to hear only about pull requests that carry it.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(model.settings.notifications.requiredLabels.sorted(), id: \.self) { label in
                        Button {
                            var updated = model.settings.notifications
                            updated.requiredLabels.remove(label)
                            preferences.wrappedValue = updated
                        } label: {
                            ComposerChip(systemImage: "xmark", tint: Theme.accent) { Text(label) }
                        }
                        .buttonStyle(.plain)
                        .help("Stop requiring the “\(label)” label")
                        .accessibilityLabel("Remove label filter \(label)")
                    }
                }
            }
        }
    }

    private func addLabel() {
        let name = labelDraft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        var updated = model.settings.notifications
        updated.requiredLabels.insert(name)
        preferences.wrappedValue = updated
        labelDraft = ""
    }

    // MARK: - Delivery

    /// Two switches, both of which a reviewer has a real opinion about.
    ///
    /// Removed from here: **grouping** notifications per project, which
    /// should simply always happen — Notification Centre threads a
    /// conversation and nobody wants twenty separate banners from one
    /// repository — and the **summary threshold**, a 1-to-25 stepper for
    /// "how many banners before you'd rather have one line". Both keep
    /// their defaults; neither is a question worth asking.
    private var deliverySection: some View {
        Section {
            Toggle("Play a sound", isOn: preferences.playSound)
                .help("Uses the system notification sound")

            Toggle("Stay quiet while I'm using Reviewrr", isOn: preferences.suppressWhileActive)
                .help("The activity is already on screen, and the dashboard's own feed has it")
        } header: {
            Text("How they arrive")
        } footer: {
            Text("A project's notifications are always grouped into one thread, and a poll that finds more than a handful of changes arrives as a single summary rather than a stack.")
        }
        .disabled(!model.settings.notifications.enabled)
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.hourLabel(hour)).tag(hour)
            }
        }
        .frame(maxWidth: 170)
        .accessibilityLabel("Quiet hours \(title.lowercased())")
    }

    private var quietSummary: String {
        let preferences = model.settings.notifications
        if preferences.quietHoursStart == preferences.quietHoursEnd {
            return "Start and end are the same hour, which silences the whole day."
        }
        let wraps = preferences.quietHoursStart > preferences.quietHoursEnd
        let span = "\(Self.hourLabel(preferences.quietHoursStart)) to \(Self.hourLabel(preferences.quietHoursEnd))"
        return wraps ? "\(span), overnight." : "\(span), same day."
    }

    private static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: - Per project

    /// The per-project override, in the notifications pane rather than only
    /// in the sidebar's context menu: "one repository is too loud" is a
    /// notification problem, and this is where a reviewer comes to solve it.
    ///
    /// Muting is here too, for the same reason. The pane used to disable a
    /// muted project's picker and tell the reviewer to go to the dashboard —
    /// a dead end in exactly the place they had come to fix it.
    @ViewBuilder
    private var projectSection: some View {
        Section {
            if model.dashboard.projects.isEmpty {
                Text("No watched projects yet. Add one from the dashboard and it will appear here.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.dashboard.projects) { project in
                    projectRow(project)
                }
            }
        } header: {
            Text("Per project")
        } footer: {
            Text("A project can only narrow these settings, never widen them: “only when my review is requested” quietens one busy repository without changing the rules for the rest. Muting goes further — a muted project contributes no notifications, no unread counts and no activity either.")
        }
        .disabled(!model.settings.notifications.enabled)
    }

    private func projectRow(_ project: WatchedProject) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("", selection: levelBinding(for: project)) {
                    ForEach(WatchedProject.NotificationLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
                .disabled(project.isMuted)
                .help(project.isMuted
                      ? "\(project.nameWithOwner) is muted, so no level applies"
                      : "How much of \(project.nameWithOwner) is worth a notification")

                Button {
                    model.dashboard.toggleMute(project)
                } label: {
                    Image(systemName: project.isMuted ? "bell.slash.fill" : "bell")
                        .foregroundStyle(project.isMuted ? .secondary : Theme.accent)
                }
                .buttonStyle(.reviewrrGhost)
                .help(project.isMuted
                      ? "Unmute \(project.nameWithOwner) — bring back its notifications, counts and activity"
                      : "Mute \(project.nameWithOwner) entirely — no notifications, no counts, no activity")
                .accessibilityLabel(project.isMuted ? "Unmute \(project.nameWithOwner)" : "Mute \(project.nameWithOwner)")
            }
        } label: {
            HStack(spacing: 6) {
                Text(project.nameWithOwner)
                    .strikethrough(project.isMuted, color: .secondary)
                    .foregroundStyle(project.isMuted ? .secondary : .primary)
                if project.isMuted {
                    StatusChip(text: "Muted", systemImage: "bell.slash", palette: .neutral)
                }
            }
        }
    }

    private func levelBinding(for project: WatchedProject) -> Binding<WatchedProject.NotificationLevel> {
        Binding(
            get: { project.notificationLevel },
            set: { model.dashboard.setNotificationLevel($0, for: project.key) }
        )
    }

    // MARK: - Hero

    /// The switch, the permission it depends on, and a way to prove it
    /// works — the three things that decide whether this feature does
    /// anything at all. Everything else on the pane is inert without them,
    /// which is why they share one card at the top.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IntegrationMark(
                    systemImage: current.enabled ? "bell.badge.fill" : "bell.slash",
                    tint: Theme.accent,
                    isActive: current.enabled && model.notifications.permission == .allowed
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text("Notifications")
                            .font(.system(size: 17, weight: .semibold))
                        StatusChip(
                            text: model.notifications.permission.label,
                            systemImage: permissionSymbol,
                            palette: permissionPalette
                        )
                        if isRequestingPermission { ProgressView().controlSize(.small) }
                    }
                    Text("Reviewrr polls only while it is open — there is no background daemon, so nothing arrives while the app is quit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Space.s)

                Toggle("", isOn: preferences.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Notify me about pull-request activity")
                    .onChange(of: model.settings.notifications.enabled) { _, isOn in
                        guard isOn else { return }
                        // The permission panel goes up in answer to this
                        // switch and nowhere else: an unprompted one at
                        // launch is the fastest way to be refused
                        // permanently.
                        isRequestingPermission = true
                        Task {
                            await model.notifications.requestPermission()
                            isRequestingPermission = false
                        }
                    }
            }

            if let remedy = model.notifications.permission.remedy {
                blockerRow(remedy, symbol: "bell.slash.fill") {
                    Button("Open System Settings") { openNotificationSettings() }
                        .buttonStyle(.reviewrrSecondary)
                    Button("Check Again") {
                        Task { await model.notifications.refreshPermission() }
                    }
                    .buttonStyle(.reviewrrGhost)
                }
            }

            // Notifications come from polling and nowhere else. With polling
            // off every control below is live but nothing can ever fire —
            // the same class of bug as a permission the reviewer cannot see.
            if current.enabled, !model.settings.pollingEnabled {
                blockerRow("Polling is off, so nothing will be found to notify about.", symbol: "pause.circle.fill") {
                    Button("Turn On Polling") {
                        model.settings.pollingEnabled = true
                        model.persistSettings()
                    }
                    .buttonStyle(.reviewrrSecondary)
                    Button("Polling Settings") { model.openSettings(.watchlist) }
                        .buttonStyle(.reviewrrGhost)
                }
            }

            if current.enabled {
                HStack(spacing: Theme.Space.s) {
                    Button {
                        didSendTest = false
                        Task { didSendTest = await model.notifications.deliverTest() }
                    } label: {
                        Label("Send a test", systemImage: "paperplane")
                    }
                    .buttonStyle(.reviewrrSecondary)
                    .help("Posts one notification now, so you can see what these settings produce")

                    if didSendTest {
                        Text("Sent — check Notification Centre if no banner appeared.")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let error = model.notifications.lastDeliveryError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    /// A named obstacle with its remedies attached, rather than a warning
    /// the reviewer has to act on somewhere else.
    private func blockerRow<Actions: View>(
        _ message: String, symbol: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.caption)
            HStack(spacing: Theme.Space.s) { actions() }
        }
        .padding(Theme.Space.m)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
    }

    // MARK: - Presets

    /// Three cards, one decision.
    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 5) {
                Text("How much should I interrupt you?")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if current.matchingPreset == nil {
                    Text("Custom")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .help("The settings in Advanced no longer match any of these")
                }
            }

            HStack(spacing: Theme.Space.s) {
                ForEach(NotificationPreset.allCases) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    private func presetCard(_ preset: NotificationPreset) -> some View {
        let isSelected = current.matchingPreset == preset
        return Button {
            preferences.wrappedValue = preset.applied(to: current)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(height: 30)

                Text(preset.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(preset.summary)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(preset.volumeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
            .padding(Theme.Space.m)
            .background(
                isSelected ? Theme.accent.opacity(0.10) : Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.7) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.summary)
        .accessibilityLabel("\(preset.label). \(preset.summary). \(preset.volumeHint)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Quiet hours

    /// One row, because it is one idea: do not interrupt me between these
    /// hours.
    private var quietHoursCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: current.quietHoursEnabled ? "moon.fill" : "moon")
                    .font(.system(size: 20))
                    .foregroundStyle(current.quietHoursEnabled ? Theme.accent : .secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiet hours")
                        .font(.callout.weight(.medium))
                    Text(current.quietHoursEnabled ? quietSummary : "Notifications arrive at any hour.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.Space.s)

                Toggle("", isOn: preferences.quietHoursEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Quiet hours")
            }

            if current.quietHoursEnabled {
                HStack(spacing: Theme.Space.m) {
                    hourPicker("From", selection: preferences.quietHoursStart)
                    hourPicker("Until", selection: preferences.quietHoursEnd)
                    Spacer()
                }
                Text("Reviewrr still collects the activity for the dashboard feed.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    // MARK: - Advanced

    /// Everything the pane used to ask up front. Reachable, not required.
    private var advancedDisclosure: some View {
        AdvancedSection(
            summary: "Individual triggers, which pull requests count, and per-project overrides — currently \(current.presetLabel)",
            itemCount: 4,
            isExpanded: $showsAdvanced
        ) {
            Form {
                whatSection
                whichSection
                deliverySection
                projectSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 460)
        }
    }
}
