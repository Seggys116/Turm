import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TopBar(isSidebarVisible: $isSidebarVisible)
            HStack(spacing: 0) {
                if isSidebarVisible {
                    ShellSidebar(workspace: workspace)
                        .transition(.move(edge: .leading))
                }
                ZStack {
                    ForEach(workspace.tabs) { tab in
                        let isActive = tab.id == workspace.activeTabID
                        TilingView(workspace: workspace, node: tab.layout, focusedPane: tab.focusedPane, isActive: isActive)
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
    ContentView()
}

enum SidebarPreference {
    static let key = "turm.sidebarVisible"
}
