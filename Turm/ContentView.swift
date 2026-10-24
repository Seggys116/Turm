import SwiftUI
import TurmCore

struct ContentView: View {
    let updater: Updater
    @State private var host = WindowHost()
    @State private var isSpotlightOpen = false
    @State private var searchAnchor: CGRect = .zero
    @State private var tileDrag = TileDrag()
    @State private var tearOffPanel = TearOffPanel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarWidthPreference.key) private var storedSidebarWidth = Double(ChromeMetrics.sidebarDefaultWidth)
    @Environment(\.dismiss) private var dismiss

    private var library: SpaceLibrary { .shared }

    private var workspace: Workspace { library.workspace(for: host) }

    private var sidebarWidth: CGFloat {
        SidebarWidthPreference.clamped(CGFloat(storedSidebarWidth))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TurmWindow(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: sidebarWidth,
                onSidebarWidth: { storedSidebarWidth = Double($0) },
                sidebar: { sidebar },
                content: { content }
            )
            searchLayer
        }
        .writingToolsBehavior(.disabled)
        .animation(ChromeMetrics.motion, value: isSpotlightOpen)
        .coordinateSpace(name: TileDrag.space)
        .onPreferenceChange(SearchAnchorKey.self) { searchAnchor = $0 }
        .background(WindowSurface())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileDrag.windowBounds = CGRect(origin: .zero, size: $0) }
        .overlay(alignment: .topLeading) { TileDropOverlay(workspace: workspace, drag: tileDrag) }
        .onChange(of: tileDrag.location) {
            if tileDrag.tearsOff { tearOffPanel.show(tileDrag.title, at: NSEvent.mouseLocation) } else { tearOffPanel.hide() }
        }
        .onChange(of: tileDrag.isActive) { _, active in
            if !active { tearOffPanel.hide() }
        }
        .onDisappear { tearOffPanel.hide() }
        .background(WindowPlacer(frame: host.placement))
        .background(WindowCloseGuard(host: host))
        .navigationTitle(workspace.focusedTitle)
        .frame(minWidth: 640, minHeight: 420)
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.spotlightPresented, $isSpotlightOpen)
        .focusedSceneValue(\.spaces, SpaceActions(library: library, host: host))
        .onAppear {
            bindEmptySpace()
            tileDrag.tearOff = tearOff
            NewWindowAction.open = { openWindow(id: WindowTransfer.windowID) }
        }
        .onChange(of: host.spaceID) { _, _ in
            bindEmptySpace()
        }
        .onChange(of: workspace.windowID) { _, _ in
            bindEmptySpace()
        }
    }

    private var sidebar: some View {
        SidebarColumn(
            library: library,
            host: host,
            searchPresented: $isSpotlightOpen,
            sidebarDocked: isSidebarVisible,
            onSettings: { workspace.openSettings() },
            onToggleSidebar: { withAnimation(ChromeMetrics.motion) { isSidebarVisible.toggle() } }
        ) {
            ShellSidebar(workspace: workspace, tileDrag: tileDrag)
        }
    }

    private var content: some View {
        let active = workspace.tabs.first { $0.id == workspace.activeTabID }
        let splits = active.map { !$0.isSettings && $0.layout.leaves.count > 1 } ?? false
        return ZStack {
            ForEach(workspace.tabs) { tab in
                let isActive = tab.id == workspace.activeTabID
                Group {
                    if tab.isSettings {
                        SettingsView(updater: updater)
                            .paneCard(isSplit: false, isFocused: false)
                    } else {
                        TilingView(
                            workspace: workspace, node: tab.layout, focusedPane: tab.focusedPane, isActive: isActive, tileDrag: tileDrag
                        )
                    }
                }
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                .zIndex(isActive ? 1 : 0)
            }
        }
        .background(Theme.terminalBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.cardCornerRadius, style: .continuous))
        .overlay {
            if !splits {
                RoundedRectangle(cornerRadius: ChromeMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TileDrag.space)) } action: { tileDrag.gridFrame = $0 }
    }
}

extension ContentView {
    private var searchLayer: some View {
        GeometryReader { geo in
            let hasAnchor = searchAnchor.width > 0
            let leading = hasAnchor ? searchAnchor.minX : ChromeMetrics.spotlightInset
            let bottom = hasAnchor ? max(0, geo.size.height - searchAnchor.maxY) : ChromeMetrics.spotlightInset
            let width = min(SpotlightPresenter.width, max(280, geo.size.width - leading - leading))
            ZStack(alignment: .bottomLeading) {
                if isSpotlightOpen {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { isSpotlightOpen = false }
                        .transition(.opacity)
                    SpotlightView(workspace: workspace, growsUpward: true) { _ in
                        isSpotlightOpen = false
                    }
                    .frame(width: width)
                    .transition(
                        .scale(scale: 0.2, anchor: .bottomLeading)
                            .combined(with: .opacity)
                            .animation(ChromeMetrics.motion)
                    )
                    .padding(.leading, leading)
                    .padding(.bottom, bottom)
                }
            }
            .animation(ChromeMetrics.motion, value: isSpotlightOpen)
        }
        .allowsHitTesting(isSpotlightOpen)
    }

    private func bindEmptySpace() {
        let boundID = host.spaceID
        workspace.onEmpty = {
            guard host.spaceID == boundID else { return }
            if library.records.count > 1, let id = boundID {
                library.dropEmpty(id, from: host)
            } else {
                dismiss()
            }
        }
    }

    private func tearOff(_ item: TileItem) -> Bool {
        tearOffPanel.hide()
        let point = NSEvent.mouseLocation
        if let target = ContextMenuService.shared.workspaceWindow(at: point, excluding: workspace) {
            guard let shell = workspace.release(item) else { return false }
            target.workspace.receive(shell)
            NSApp.activate()
            target.window.makeKeyAndOrderFront(nil)
            return true
        }
        guard workspace.canTearOff(item), let shell = workspace.release(item) else { return false }
        let size = NSApp.keyWindow?.frame.size ?? CGSize(width: 900, height: 600)
        WindowTransfer.shared.enqueue(shell, frame: WindowTransfer.frame(size: size, at: point))
        openWindow(id: WindowTransfer.windowID)
        return true
    }
}

#Preview {
    ContentView(updater: Updater())
}

enum SidebarPreference {
    static let key = "turm.sidebarVisible"
}
