import SwiftTerm
import SwiftUI
import UIKit

/// How a wide window divides the sidebar and the session.
///
/// Side by side only when the system will keep two columns: a regular width (iPad, a large phone
/// in landscape, iPhone Duo unfolded) or an active vertical fold with room on both sides.
/// A compact phone, in either orientation, stays a stack so the sidebar is a page you can return to.
struct ShellLayout {
    var split: Bool
    var sidebarWidth: CGFloat
    var detailLeading: CGFloat

    init(horizontal: UserInterfaceSizeClass?, width: CGFloat, fold: ClosedRange<CGFloat>? = nil) {
        let foldSplits = fold.map { $0.lowerBound >= 220 && width - $0.upperBound >= 280 } ?? false
        split = horizontal == .regular || foldSplits
        guard split, width > 1 else {
            sidebarWidth = max(width, 1)
            detailLeading = 0
            return
        }
        let range: ClosedRange<CGFloat> = horizontal == .regular ? 260...420 : 240...360
        sidebarWidth = min(max(width * 0.34, range.lowerBound), range.upperBound)
        detailLeading = sidebarWidth
        if let fold, fold.lowerBound >= 220, width - fold.upperBound >= 280 {
            sidebarWidth = fold.lowerBound
            detailLeading = fold.upperBound
        }
    }
}

struct AdaptiveShell: View {
    let workspace: Workspace
    let macs: MacManager
    @Environment(\.horizontalSizeClass) private var horizontal
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    @State private var width: CGFloat = 0
    @State private var fold: ClosedRange<CGFloat>?
    @State private var homePath: [HomeRoute] = []

    private var layout: ShellLayout {
        ShellLayout(horizontal: horizontal, width: width, fold: fold)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            NavigationStack(path: $homePath) {
                AppSidebar(workspace: workspace, macs: macs, path: $homePath)
                    .navigationDestination(for: HomeRoute.self) { route in
                        homeDestination(route)
                    }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: max(layout.sidebarWidth, 220), max: 560)
        } detail: {
            TerminalDetail(workspace: workspace)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.splitLayout, layout.split)
        .background { MacClosePrompt(macs: macs) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fold = ReservedArea.verticalFold(in: proxy) }
                    .onChange(of: proxy.size) { _, _ in fold = ReservedArea.verticalFold(in: proxy) }
            }
        }
        .onChange(of: homePath) { _, path in
            guard path.count >= 2, path[path.count - 1] == path[path.count - 2] else { return }
            homePath.removeLast()
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard layout.split else { return }
            switch visibility {
            case .detailOnly:
                if !workspace.sidebarHidden { workspace.sidebarHidden = true }
            case .doubleColumn, .all:
                if workspace.sidebarHidden { workspace.sidebarHidden = false }
            default:
                break
            }
        }
        .onChange(of: workspace.sidebarHidden) { _, hidden in
            if layout.split {
                revealColumns(hidden)
            } else {
                preferredColumn = hidden ? .detail : .sidebar
                workspace.compactColumn = hidden ? .detail : .sidebar
            }
        }
        .onChange(of: layout.split) { _, split in
            if split {
                revealColumns(workspace.sidebarHidden)
            } else {
                if columnVisibility != .automatic { columnVisibility = .automatic }
                let page: NavigationSplitViewColumn = workspace.selectedID == nil ? .sidebar : .detail
                preferredColumn = page
                workspace.compactColumn = page == .sidebar ? .sidebar : .detail
            }
        }
        .onChange(of: workspace.compactColumn) { _, column in
            show(column)
        }
        .onChange(of: workspace.selectedID) { _, id in
            let column: WorkspaceColumn = id == nil ? .sidebar : .detail
            workspace.compactColumn = column
            if !layout.split { preferredColumn = column == .sidebar ? .sidebar : .detail }
            focus(for: column)
        }
        .onAppear { show(workspace.compactColumn) }
    }

    @ViewBuilder
    private func homeDestination(_ route: HomeRoute) -> some View {
        switch route {
        case .mac(let id):
            if let connection = macs.connection(for: id), let entry = macs.macs.first(where: { $0.id == id }) {
                MacSpacesPage(workspace: workspace, macs: macs, connection: connection, entry: entry, path: $homePath)
            } else {
                ContentUnavailableView("Mac Unavailable", systemImage: "desktopcomputer", description: Text("This Mac is no longer paired."))
            }
        case .space(let macID, let spaceID):
            if let connection = macs.connection(for: macID) {
                let group = MacSpaces.groups(in: connection.sessions).first { $0.id == spaceID }
                    ?? MacSpaceGroup(id: spaceID, name: "Space", symbol: "terminal", sessions: [])
                MacSpaceShells(workspace: workspace, connection: connection, group: group)
            } else {
                ContentUnavailableView("Mac Unavailable", systemImage: "desktopcomputer", description: Text("This Mac is no longer paired."))
            }
        }
    }

    /// A column chosen before this view exists still has to be the one on screen.
    private func show(_ column: WorkspaceColumn) {
        guard !layout.split else {
            revealColumns(workspace.sidebarHidden)
            return
        }
        let next: NavigationSplitViewColumn = column == .sidebar ? .sidebar : .detail
        if preferredColumn != next { preferredColumn = next }
    }

    /// Both columns stay up until the sidebar is hidden. `.automatic` would collapse them again
    /// as soon as a session is selected.
    private func revealColumns(_ hidden: Bool) {
        let next: NavigationSplitViewVisibility = hidden ? .detailOnly : .doubleColumn
        if columnVisibility != next { columnVisibility = next }
    }

    private func focus(for column: WorkspaceColumn) {
        switch column {
        case .sidebar:
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        case .detail:
            if let ssh = workspace.selected as? SSHTerminalSession, !ssh.usesBlocks { _ = ssh.surface.view.becomeFirstResponder() }
        }
    }
}

/// Stays mounted for the life of the window, so a close confirmation is shown on the swipe
/// instead of waiting until a later page appears.
private struct MacClosePrompt: View {
    let macs: MacManager
    @Environment(\.chromeOverlays) private var overlays
    @State private var token = UUID()

    private var pendingID: UUID? {
        macs.connections.compactMap(\.closeRequest).first?.id
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: pendingID, initial: true) { _, id in
                show(id)
            }
    }

    private func show(_ id: UUID?) {
        guard let overlays else { return }
        guard let id,
              let connection = macs.connections.first(where: { $0.closeRequest?.id == id }),
              let request = connection.closeRequest
        else {
            overlays.dismissDialog(token: token)
            return
        }
        overlays.present(
            dialog: ChromeDialogSpec(
                title: "Close this shell?",
                message: request.message,
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Close Anyway", role: .destructive) { _ in
                        connection.closeSession(request.id, force: true)
                    },
                ]
            ),
            token: token
        ) {
            if connection.closeRequest?.id == request.id {
                connection.closeRequest = nil
            }
        }
    }
}
