import SwiftUI

struct ContentView: View {
    let updater: Updater
    @State private var workspace = Workspace()
    @State private var isSpotlightOpen = false
    @State private var spotlight = SpotlightPresenter()
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarPlacement.key) private var placement = SidebarPlacement.left
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                isSidebarVisible: $isSidebarVisible, placement: placement, onOpenSettings: { workspace.openSettings() },
                spotlight: spotlight, isSpotlightOpen: isSpotlightOpen, onSpotlight: { isSpotlightOpen = true }
            )
                .zIndex(1)
            if isSidebarVisible, placement == .top {
                ShellSidebar(workspace: workspace, placement: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if isSidebarVisible, placement == .left {
                    ShellSidebar(workspace: workspace, placement: .left)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ZStack {
                    ForEach(workspace.tabs) { tab in
                        let isActive = tab.id == workspace.activeTabID
                        Group {
                            if tab.isSettings {
                                SettingsView(updater: updater)
                            } else {
                                TilingView(workspace: workspace, node: tab.layout, focusedPane: tab.focusedPane, isActive: isActive)
                            }
                        }
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                            .zIndex(isActive ? 1 : 0)
                    }
                }
            }
            .clipped()
        }
        .animation(.easeInOut(duration: 0.18), value: placement)
        .animation(.easeInOut(duration: 0.18), value: isSidebarVisible)
        .ignoresSafeArea(.container, edges: .top)
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
            }
    }
}

#Preview {
    ContentView(updater: Updater())
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
