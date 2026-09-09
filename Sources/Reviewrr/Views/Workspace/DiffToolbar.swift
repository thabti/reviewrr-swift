import SwiftUI

/// Sticky bar above the diff content: layout + word-wrap toggles (both
/// persisted to `AppSettings`) and file/change/comment navigation. Lives
/// inside `DiffContainerView`'s own content rather than as a window
/// `.toolbar` item, so it never has to coordinate placement with the
/// integrator's `RootView` toolbar.
///
/// Exactly `Theme.panelHeaderHeight` tall on the same `Space.m` inset as
/// the sidebar header beside it, so the three columns of the workspace
/// start their content on one line.
struct DiffToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var workspace: WorkspaceModel



    var body: some View {
        HStack(spacing: 12) {
            // Presentation only. Navigation moved to `DiffNavigationBar`,
            // floating at the bottom of the pane: the arrows are pressed
            // constantly and belong near the code, while layout and wrap are
            // set once and forgotten.
            presentationGroup

            Spacer(minLength: Theme.Space.s)

            Button {
                workspace.showShortcuts = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.reviewrrGhost)
            .help("Keyboard shortcuts (?)")
            .accessibilityLabel("Show keyboard shortcuts")
        }
        .font(Theme.body)
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 48)
        .background(Theme.barMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Groups

    /// How the diff is *drawn*. Layout and wrap belong together — they
    /// answer the same question — and used to sit a bare 10pt from the
    /// navigation arrows with no rule between them, so the wrap toggle read
    /// as a third segment of the split/unified control.
    private var presentationGroup: some View {
        HStack(spacing: Theme.Space.xs) {
            Picker("Layout", selection: layoutBinding) {
                ForEach(DiffLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Diff layout: \(model.settings.diffLayout.label) — press u to switch")
            .accessibilityLabel("Diff layout, currently \(model.settings.diffLayout.label)")

            Toggle(isOn: wordWrapBinding) {
                Image(systemName: "text.word.spacing")
            }
            .toggleStyle(.button)
            .help(model.settings.wordWrap
                  ? "Word wrap on — long lines fold onto the next line"
                  : "Word wrap off — long lines scroll sideways")
            .accessibilityLabel(model.settings.wordWrap ? "Turn word wrap off" : "Turn word wrap on")
        }
    }

    /// Where the diff is *positioned*: three back/forward pairs. Spacing
    /// carries the structure — `xs` inside a pair, `s` between pairs — so
    /// six arrows need one rule to separate them from the group before,
    /// not three.



    private var layoutBinding: Binding<DiffLayout> {
        Binding(
            get: { model.settings.diffLayout },
            set: { model.settings.diffLayout = $0; model.persistSettings() }
        )
    }

    private var wordWrapBinding: Binding<Bool> {
        Binding(
            get: { model.settings.wordWrap },
            set: { model.settings.wordWrap = $0; model.persistSettings() }
        )
    }



}
