import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

extension EnvironmentValues {
    /// Whether AdaptiveShell shows the sidebar and the detail side by side, per ShellLayout.
    @Entry var splitLayout = false
}

struct ContentView: View {
    #if targetEnvironment(simulator)
    private static let initialWorkspace = DemoContent.workspace() ?? Workspace()
    #else
    private static let initialWorkspace = Workspace()
    #endif

    @State private var workspace = Self.initialWorkspace
    @State private var swipes = SwipeCoordinator()
    var macs = MacManager.shared

    var body: some View {
        @Bindable var workspace = workspace
        AdaptiveShell(workspace: workspace, macs: macs)
            .chromeOverlayHost()
            .tint(Chrome.accent)
            .environment(\.swipeCoordinator, swipes)
            .toggleStyle(ChromeToggleStyle())
            .sheet(isPresented: $workspace.showsSettings) {
                SettingsView()
            }
            .sheet(isPresented: $workspace.showsHostPicker) {
                HostPicker(workspace: workspace)
            }
            .sheet(isPresented: $workspace.showsPairing) {
                PairMacView(manager: macs)
            }
            .sheet(item: $workspace.editingHost) { host in
                SSHHostEditorView(host) { workspace.editingHost = nil }
            }
            .focusedSceneValue(\.workspace, workspace)
            #if targetEnvironment(simulator)
            .task { await DemoContent.presentSheets(in: workspace) }
            #endif
    }
}
