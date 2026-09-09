import SwiftUI

/// The app's home screen: watched projects on the left, the combined
/// cross-repository PR inbox on the right. Self-contained two-pane layout
/// (rather than nesting another `NavigationSplitView`) so it renders the
/// same whether the integrator hosts it as `RootView`'s detail content or
/// anywhere else.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    /// The host travels with the reference: the inbox mixes rows from
    /// every watched host, and a reference alone cannot say which server it
    /// belongs to.
    let onOpenPR: (PRReference, ForgeHost) -> Void

    @State private var selectedRowID: String?
    @FocusState private var searchFocused: Bool
    /// Sidebar width is the reviewer's call — repository names vary wildly in
    /// length — so it is draggable and remembered.
    @AppStorage("reviewrr.dashboard.sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("reviewrr.dashboard.sidebarCollapsed") private var sidebarCollapsed = false

    private static let minSidebarWidth: Double = 200
    private static let maxSidebarWidth: Double = 460

    init(model: DashboardModel, onOpenPR: @escaping (PRReference, ForgeHost) -> Void) {
        self.model = model
        self.onOpenPR = onOpenPR
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                ProjectSidebarView(model: model, showAddProject: $model.isAddProjectPresented)
                    .frame(width: sidebarWidth)
                    .motionTransition(.move(edge: .leading).combined(with: .opacity))

                resizeHandle
            }

            InboxPanelView(
                model: model, selectedRowID: $selectedRowID, searchFocused: $searchFocused,
                showAddProject: $model.isAddProjectPresented,
                sidebarCollapsed: $sidebarCollapsed,
                onSelectRow: openRow, onResumeDraft: { onOpenPR($0, model.host) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .motion(Motion.surface, value: sidebarCollapsed)
        .environment(\.reviewrrTextScale, model.textScale)
        .sheet(isPresented: $model.isAddProjectPresented) {
            AddProjectSheet(model: model)
        }
        .task {
            model.start()
            await model.refreshAll(force: false)
            model.reloadSavedReviews(includeLegacyInProgress: true)
        }
        .onDisappear { model.stop() }

    }

    /// A one-pixel divider is a two-pixel target, so the draggable area is
    /// widened invisibly and the cursor changes to say it can be dragged.
    private var resizeHandle: some View {
        Divider()
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                sidebarWidth = min(
                                    max(sidebarWidth + value.translation.width - dragAccumulator, Self.minSidebarWidth),
                                    Self.maxSidebarWidth
                                )
                                dragAccumulator = value.translation.width
                            }
                            .onEnded { _ in dragAccumulator = 0 }
                    )
                    .accessibilityLabel("Resize sidebar")
            }
    }

    // Drag translation is cumulative from the gesture's start, so the last
    // reported value is subtracted to turn it into a per-frame delta.
    @State private var dragAccumulator: CGFloat = 0

    private func openRow(_ pr: InboxPR) {
        model.markOpened(pr)
        // The row knows which host it came from; the reference does not.
        onOpenPR(pr.reference, pr.host)
    }
}
