import SwiftUI

/// The app's home screen: watched projects in the sidebar, the combined
/// cross-repository PR inbox as the detail.
///
/// A real `NavigationSplitView`, which is what makes it behave like a Mac
/// app rather than an approximation of one. It replaces a hand-rolled
/// `HStack` with a drag handle, an `@AppStorage` width and an
/// `@AppStorage` collapsed flag — all of which macOS already does, and does
/// better: the system's own drag-to-resize with its snap behaviour, the
/// standard sidebar toggle in the toolbar with its ⌃⌘S binding, the
/// full-height vibrant sidebar material, and a remembered width per window
/// rather than per app.
///
/// Losing the custom toggle button is part of the point. There were two —
/// one in the inbox's filter bar and one in its toolbar — and neither was
/// the one a Mac user reaches for.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    /// The host travels with the reference: the inbox mixes rows from
    /// every watched host, and a reference alone cannot say which server it
    /// belongs to.
    let onOpenPR: (PRReference, ForgeHost) -> Void

    @State private var selectedRowID: String?
    @FocusState private var searchFocused: Bool
    /// Starts with both columns shown. macOS remembers what the reviewer
    /// does with it from there, per window, as it does for every other
    /// split view on the system.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(model: DashboardModel, onOpenPR: @escaping (PRReference, ForgeHost) -> Void) {
        self.model = model
        self.onOpenPR = onOpenPR
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(model: model, showAddProject: $model.isAddProjectPresented)
                // A range, not a fixed width: the system's drag handle needs
                // room to work, and repository names vary wildly in length.
                .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 460)
        } detail: {
            InboxPanelView(
                model: model, selectedRowID: $selectedRowID, searchFocused: $searchFocused,
                showAddProject: $model.isAddProjectPresented,
                onSelectRow: openRow, onResumeDraft: { onOpenPR($0, model.host) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.reviewrrTextScale, model.textScale)
        .sheet(isPresented: $model.isAddProjectPresented) {
            AddProjectSheet(model: model)
        }
        // Polling is *not* started or stopped here. It belongs to the app's
        // lifetime, not this view's: the dashboard is torn down whenever a
        // pull request or the settings pane takes the window, and stopping
        // the poller there stopped every notification for as long as the
        // reviewer was actually reviewing. `RootView` owns it now.
        .task {
            await model.refreshAll(force: false)
            model.reloadSavedReviews(includeLegacyInProgress: true)
        }

    }

    /// A one-pixel divider is a two-pixel target, so the draggable area is
    /// widened invisibly and the cursor changes to say it can be dragged.
    // Drag translation is cumulative from the gesture's start, so the last
    // reported value is subtracted to turn it into a per-frame delta.
    @State private var dragAccumulator: CGFloat = 0

    private func openRow(_ pr: InboxPR) {
        model.markOpened(pr)
        // The row knows which host it came from; the reference does not.
        onOpenPR(pr.reference, pr.host)
    }
}
