import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TilingView(workspace: workspace, node: workspace.layout)
            .background(Color.black)
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
