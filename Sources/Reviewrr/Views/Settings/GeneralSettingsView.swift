import SwiftUI

/// Appearance, and what a pull request opens as.
///
/// Every setting here is a *taste*, not a configuration: there is no wrong
/// answer and nothing to get working. So it leads with the choice a
/// reviewer can see the result of — light or dark, as three cards showing
/// what they mean — and puts the rest in one plain list of rows.
struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showsAdvanced = false

    private var settings: AppSettings { model.settings }

    var body: some View {
        SettingsPage {
            SettingsHero(
                title: "Appearance",
                subtitle: "How Reviewrr looks, and what a pull request opens as. None of this affects what a review does.",
                tile: AnyView(SettingsTile(systemImage: "paintbrush.fill"))
            )

            PresetRow(question: "Theme") {
                ForEach(Appearance.allCases) { appearance in
                    PresetCard(
                        systemImage: symbol(for: appearance),
                        title: appearance.label,
                        summary: summary(for: appearance),
                        hint: nil,
                        isSelected: settings.appearance == appearance
                    ) {
                        model.settings.appearance = appearance
                        model.persistSettings()
                    }
                }
            }

            SettingsField(title: "Text size", systemImage: "textformat.size", note: "Scales interface text. Code in the diff keeps its own size, so a wider setting never reflows a patch.") {
                Picker("Text size", selection: $model.settings.textSize) {
                    ForEach(InterfaceTextSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.settings.textSize) { _, _ in model.persistSettings() }
                .accessibilityLabel("Interface text size")
            }

            AdvancedSection(
                summary: "What a pull request opens as, and where Reviewrr starts",
                itemCount: 3,
                isExpanded: $showsAdvanced
            ) {
                AdvancedGroup(
                    title: "Opening a pull request",
                    note: "Applies to the next pull request you open; ones already open keep their layout. Press u in the diff to switch layout at any time."
                ) {
                    Picker("Diff layout", selection: $model.settings.diffLayout) {
                        ForEach(DiffLayout.allCases) { layout in
                            Label(layout.label, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: model.settings.diffLayout) { _, _ in model.persistSettings() }
                    .accessibilityLabel("Default diff layout")

                    Toggle("Wrap long lines", isOn: $model.settings.wordWrap)
                        .onChange(of: model.settings.wordWrap) { _, _ in model.persistSettings() }
                        .help("On folds a long line onto the next; off scrolls it sideways")
                }

                AdvancedGroup(
                    title: "On launch",
                    note: "Off reopens whatever you were last reviewing, which is usually where you want to be."
                ) {
                    Toggle("Start on the dashboard", isOn: $model.settings.startOnDashboard)
                        .onChange(of: model.settings.startOnDashboard) { _, _ in model.persistSettings() }
                }
            }
        }
    }

    private func symbol(for appearance: Appearance) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.stars"
        }
    }

    private func summary(for appearance: Appearance) -> String {
        switch appearance {
        case .system: return "Follows macOS, switching with it through the day."
        case .light: return "Always light, whatever macOS is doing."
        case .dark: return "Always dark, whatever macOS is doing."
        }
    }
}
