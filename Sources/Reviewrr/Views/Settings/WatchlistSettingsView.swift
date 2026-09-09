import SwiftUI

/// How often Reviewrr checks your watched projects.
///
/// ## What was removed
///
/// A stepper for the interval in 30-second increments, a second stepper for
/// the maximum backoff, and a **jitter slider** measured in percent. Jitter
/// exists so a reviewer watching twenty projects does not fire twenty
/// requests in the same second — it is a correctness detail of the polling
/// loop, and no reviewer has an opinion about 20% versus 30% of it. The
/// backoff ceiling is the same kind of thing.
///
/// Both keep their existing defaults in `AppSettings`; they are simply not
/// asked about any more. What is left is the one thing a reviewer does have
/// a view on: how fresh they want the inbox, traded against how much they
/// want the app talking to the network.
struct WatchlistSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showsAdvanced = false

    private var settings: AppSettings { model.settings }

    private var currentRate: PollRate? {
        PollRate.allCases.first { $0.rawValue == settings.pollIntervalSeconds }
    }

    var body: some View {
        SettingsPage {
            SettingsHero(
                title: "Checking for activity",
                subtitle: "Reviewrr checks your watched projects while it is open. There is no background daemon — nothing runs when the app is quit.",
                tile: AnyView(SettingsTile(
                    systemImage: settings.pollingEnabled ? "arrow.triangle.2.circlepath" : "pause.circle",
                    isActive: settings.pollingEnabled
                )),
                status: settings.pollingEnabled ? .ready("On") : .off
            ) {
                Toggle("", isOn: $model.settings.pollingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: model.settings.pollingEnabled) { _, isOn in
                        model.persistSettings()
                        // The coordinator reads this switch once, when it is
                        // started. Without re-running it here, turning
                        // polling back on left the app doing nothing until
                        // the next launch — and with it, every notification.
                        if isOn { model.dashboard.start() } else { model.dashboard.stop() }
                    }
                    .accessibilityLabel("Check watched projects for activity")
            }

            if settings.pollingEnabled {
                PresetRow(
                    question: "How fresh should the inbox be?",
                    isCustom: currentRate == nil,
                    customHelp: "The interval was set to something other than these three"
                ) {
                    ForEach(PollRate.allCases) { rate in
                        PresetCard(
                            systemImage: rate.systemImage,
                            title: rate.label,
                            summary: rate.summary,
                            hint: rate.hint,
                            isSelected: currentRate == rate
                        ) {
                            model.settings.pollIntervalSeconds = rate.rawValue
                            // The ceiling follows the rate rather than being
                            // asked about: a backoff below the interval is
                            // meaningless, and one far above it strands a
                            // failing project for an hour.
                            model.settings.maxPollIntervalSeconds = max(rate.rawValue * 6, 1_800)
                            model.persistSettings()
                        }
                    }
                }

                activityCard
            }

            AdvancedSection(
                summary: "The in-app activity feed, and where system notifications live",
                itemCount: 2,
                isExpanded: $showsAdvanced
            ) {
                AdvancedGroup(
                    title: "Activity feed",
                    note: "Collects what changed since you last looked, under the bell in the dashboard. Independent of macOS notifications."
                ) {
                    Toggle("Keep an in-app activity feed", isOn: $model.settings.inAppActivityEnabled)
                        .onChange(of: model.settings.inAppActivityEnabled) { _, _ in model.persistSettings() }
                }

                AdvancedGroup(
                    title: "System notifications",
                    note: "Which events are worth interrupting you, and quiet hours, live in their own pane."
                ) {
                    Button {
                        model.openSettings(.notifications)
                    } label: {
                        Label(
                            settings.notifications.enabled ? "Notifications are on — configure" : "Notifications are off — set up",
                            systemImage: settings.notifications.enabled ? "bell.badge" : "bell.slash"
                        )
                    }
                    .buttonStyle(.reviewrrSecondary)
                }
            }
        }
    }

    /// The one number worth showing rather than setting: what the current
    /// rate costs in requests.
    private var activityCard: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Each check is a few requests per project")
                    .font(.callout.weight(.medium))
                Text("Reviewrr staggers them so watched projects never all refresh in the same second, and backs off automatically when a host is rate limiting or unreachable.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
    }
}
