import SwiftUI
import UIKit

/// How the window is divided between the sidebar and the session detail.
struct ShellLayout {
    static let wideCompactWidth: CGFloat = 640

    var split: Bool
    var sidebarWidth: CGFloat
    var detailLeading: CGFloat

    /// Side by side for regular width, and for short compact windows at least 640pt wide; one column otherwise.
    init(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?, width: CGFloat, fold: ClosedRange<CGFloat>? = nil) {
        let regular = horizontal == .regular
        split = regular || (vertical == .compact && width >= Self.wideCompactWidth)
        guard split else {
            sidebarWidth = width
            detailLeading = 0
            return
        }
        let range: ClosedRange<CGFloat> = regular ? 260...360 : 240...300
        sidebarWidth = min(max(width * 0.3, range.lowerBound), range.upperBound)
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
    @Environment(\.verticalSizeClass) private var vertical
    @GestureState(resetTransaction: Transaction(animation: Chrome.columnMotion)) private var edgeDrag: CGFloat = 0

    var body: some View {
        ToolbarVerticalEdgeReader { rail in
            GeometryReader { proxy in
                shell(in: proxy, rail: rail)
            }
        }
        .background(Chrome.sidebar.ignoresSafeArea())
    }

    private func shell(in proxy: GeometryProxy, rail: HorizontalEdge?) -> some View {
        let insets = proxy.safeAreaInsets
        let strip = rail == .leading ? insets.leading : rail == .trailing ? insets.trailing : 0
        let inStrip = strip >= Chrome.Metrics.minimumStrip
        let railWidth = rail == nil || inStrip ? 0 : Chrome.Metrics.railWidth
        let leadingRail = rail == .leading ? railWidth : 0
        let width = max(0, proxy.size.width - railWidth)
        let fold = ReservedArea.verticalFold(in: proxy).map { ($0.lowerBound - leadingRail)...($0.upperBound - leadingRail) }
        let layout = ShellLayout(horizontal: horizontal, vertical: vertical, width: width, fold: fold)
        let split = layout.split
        let sidebarShown = split ? !workspace.sidebarHidden : workspace.compactColumn == .sidebar
        let detailShown = split || workspace.compactColumn == .detail
        let detailX = split && !workspace.sidebarHidden ? layout.detailLeading : 0
        let sidebarSlide = split && workspace.sidebarHidden ? -(layout.sidebarWidth + insets.leading + leadingRail) : 0
        let detailSlide = !split && workspace.compactColumn == .sidebar ? proxy.size.width + insets.leading + insets.trailing : 0
        return ZStack(alignment: .topLeading) {
            AppSidebar(workspace: workspace, macs: macs)
                .frame(width: layout.sidebarWidth)
                .overlay(alignment: .trailing) {
                    if split { Chrome.divider.frame(width: 1).ignoresSafeArea(edges: .vertical) }
                }
                .offset(x: sidebarSlide)
                .animation(Chrome.columnMotion, value: sidebarSlide)
                .accessibilityHidden(!sidebarShown)
            TerminalDetail(workspace: workspace)
                .frame(width: max(0, width - detailX))
                .overlay(alignment: .leading) {
                    if !split { Chrome.divider.frame(width: 1).ignoresSafeArea(edges: .vertical) }
                }
                .simultaneousGesture(edgeSwipe(width: width), isEnabled: !split && detailShown)
                .padding(.leading, detailX)
                .transaction(value: detailX) { $0.animation = nil }
                .offset(x: detailSlide)
                .animation(Chrome.columnMotion, value: detailSlide)
                .offset(x: edgeDrag)
                .accessibilityHidden(!detailShown)
        }
        .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        .environment(\.splitLayout, split)
        .environment(\.chromeBarSuppressed, rail != nil)
        .modifier(ChromeBarPlacement(bar: railBar(split: split), top: nil, side: inStrip ? nil : rail))
        .overlay(alignment: rail == .leading ? .topLeading : .topTrailing) {
            if inStrip, let rail {
                stripBar(split: split, side: rail, width: strip, insets: insets, height: proxy.size.height)
            }
        }
        .onChange(of: workspace.compactColumn) { _, column in
            guard !split else { return }
            focus(for: column)
        }
    }

    /// The iPhone Duo vertical bar: navigation first, then the app actions, then the open session's actions.
    private func railBar(split: Bool) -> some View {
        let detailShown = split || workspace.compactColumn == .detail
        return ChromeTopBar(
            workspace.selected?.title ?? "Turm",
            leading: {
                if split {
                    SidebarToggleButton(workspace: workspace)
                } else if detailShown {
                    SessionsBackButton(workspace: workspace)
                }
            },
            trailing: {
                NewMenuButton(workspace: workspace)
                SettingsButton(workspace: workspace)
                if detailShown, let tab = workspace.selected {
                    SessionButtons(workspace: workspace, tab: tab)
                }
            }
        )
    }

    // the system's vertical status strip is also where Apple puts an app's vertical bar, below the camera and status
    private func stripBar(split: Bool, side: HorizontalEdge, width: CGFloat, insets: EdgeInsets, height: CGFloat) -> some View {
        railBar(split: split)
            .environment(\.chromeBarStyle, .vertical(side))
            .padding(.bottom, insets.bottom)
            .frame(width: width, height: height + insets.top + insets.bottom)
            .ignoresSafeArea()
            .offset(x: side == .trailing ? width : -width, y: -insets.top)
    }

    private func focus(for column: WorkspaceColumn) {
        switch column {
        case .sidebar:
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        case .detail:
            if let ssh = workspace.selected as? SSHTerminalSession, !ssh.usesBlocks { _ = ssh.surface.view.becomeFirstResponder() }
        }
    }

    // only drags that start at the leading edge pull the sessions back in; a cancelled drag (the scroll view took it) resets the offset
    private func edgeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($edgeDrag) { value, offset, _ in
                guard value.startLocation.x <= 22, abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = max(0, value.translation.width)
            }
            .onEnded { value in
                let sideways = value.translation.width > abs(value.translation.height)
                guard value.startLocation.x <= 22, value.translation.width > 0, sideways else { return }
                let leave = value.translation.width > width * 0.35 || value.predictedEndTranslation.width > width * 0.6
                if leave { withAnimation(Chrome.columnMotion) { workspace.compactColumn = .sidebar } }
            }
    }
}
