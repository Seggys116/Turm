import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TilingView(workspace: workspace, node: workspace.layout)
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
