import SwiftUI

struct ContentView: View {
    let updater: Updater
    @State private var holder = WorkspaceHolder()
    @State private var isSpotlightOpen = false
    @State private var spotlight = SpotlightPresenter()
    @State private var tileDrag = TileDrag()
    @State private var tearOffPanel = TearOffPanel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarPlacement.key) private var placement = SidebarPlacement.left
    @Environment(\.dismiss) private var dismiss

    private var workspace: Workspace { holder.workspace }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                isSidebarVisible: $isSidebarVisible, placement: placement, onOpenSettings: { workspace.openSettings() },
                spotlight: spotlight, isSpotlightOpen: isSpotlightOpen, onSpotlight: { isSpotlightOpen = true }
            )
                .zIndex(1)
            if isSidebarVisible, placement == .top {
                ShellSidebar(workspace: workspace, placement: .top, tileDrag: tileDrag)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if isSidebarVisible, placement == .left {
                    ShellSidebar(workspace: workspace, placement: .left, tileDrag: tileDrag)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ZStack {
                    ForEach(workspace.tabs) { tab in
                        let isActive = tab.id == workspace.activeTabID
                        Group {
                            if tab.isSettings {
                                SettingsView(updater: updater)
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TileDrag.space)) } action: { tileDrag.gridFrame = $0 }
            }
            .clipped()
        }
        .animation(.easeInOut(duration: 0.18), value: placement)
        .animation(.easeInOut(duration: 0.18), value: isSidebarVisible)
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: TileDrag.space)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileDrag.windowBounds = CGRect(origin: .zero, size: $0) }
        .overlay(alignment: .topLeading) { TileDropOverlay(workspace: workspace, drag: tileDrag) }
        .onChange(of: tileDrag.location) {
            if tileDrag.tearsOff { tearOffPanel.show(tileDrag.title, at: NSEvent.mouseLocation) } else { tearOffPanel.hide() }
        }
        .onChange(of: tileDrag.isActive) { _, active in
            if !active { tearOffPanel.hide() }
        }
        .onDisappear { tearOffPanel.hide() }
        .background(WindowPlacer(frame: holder.placement))
        .background(Theme.terminalBackground.color)
        .background(WindowCloseGuard(workspace: workspace))
        .overlay {
            if isSpotlightOpen {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isSpotlightOpen)
        .onChange(of: isSpotlightOpen) { _, open in
            if open {
                let view = SpotlightView(workspace: workspace) { launched in
                    spotlight.restoresFocus = !launched
                    isSpotlightOpen = false
                }
                spotlight.present(view) { isSpotlightOpen = false }
                if !spotlight.isPresented { isSpotlightOpen = false }
            } else {
                spotlight.dismiss()
            }
        }
            .navigationTitle(workspace.focusedTitle)
            .frame(minWidth: 320, minHeight: 200)
            .focusedSceneValue(\.workspace, workspace)
            .focusedSceneValue(\.spotlightPresented, $isSpotlightOpen)
            .onAppear {
                workspace.onEmpty = { dismiss() }
                tileDrag.tearOff = tearOff
            }
    }
}

extension ContentView {
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

// @State evaluates its initial value on every view init, so the shell starts on first use instead
final class WorkspaceHolder {
    var placement: NSRect? {
        _ = workspace
        return pendingFrame
    }
    private var pendingFrame: NSRect?
    private(set) lazy var workspace: Workspace = {
        let pending = WindowTransfer.shared.take()
        pendingFrame = pending?.frame
        return Workspace(transfer: pending?.shell)
    }()
}

enum SidebarPreference {
    static let key = "turm.sidebarVisible"
}

enum SidebarPlacement: String, CaseIterable, Identifiable {
    case left
    case top

    static let key = "turm.sidebarPlacement"

    var id: Self { self }

    var title: String {
        switch self {
        case .left: "Left"
        case .top: "Top"
        }
    }

    var noun: String {
        self == .top ? "Tab Bar" : "Sidebar"
    }

    var symbol: String {
        switch self {
        case .left: "sidebar.left"
        case .top: "rectangle.topthird.inset.filled"
        }
    }
}
