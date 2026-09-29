import SwiftUI

struct ContentView: View {
    let updater: Updater
    @State private var workspace = Workspace()
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarPlacement.key) private var placement = SidebarPlacement.left
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TopBar(isSidebarVisible: $isSidebarVisible, placement: placement, onOpenSettings: { workspace.openSettings() })
                .zIndex(1)
            if isSidebarVisible, placement == .top {
                ShellSidebar(workspace: workspace, placement: .top)
                    .transition(.move(edge: .top))
            }
            HStack(spacing: 0) {
                if isSidebarVisible, placement == .left {
                    ShellSidebar(workspace: workspace, placement: .left)
                        .transition(.move(edge: .leading))
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
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.terminalBackground.color)
        .background(WindowCloseGuard(workspace: workspace))
            .navigationTitle(workspace.focusedTitle)
            .frame(minWidth: 320, minHeight: 200)
            .focusedSceneValue(\.workspace, workspace)
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
