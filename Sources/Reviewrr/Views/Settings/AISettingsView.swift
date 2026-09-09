import SwiftUI

/// Thin host for Track E's AI provider pane. Track B does not know (and
/// must not reference) the concrete provider-settings view type; it is
/// handed in as an already-erased `AnyView` by whoever wires the two
/// tracks together.
struct AISettingsView: View {
    let pane: AnyView

    var body: some View {
        // The AI pane brings its own grouped Form, so it needs no inset
        // from this host — see the note in the other panes.
        pane
    }
}
