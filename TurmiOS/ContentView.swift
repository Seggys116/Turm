import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

extension EnvironmentValues {
    /// Whether AdaptiveShell shows the sidebar and the detail side by side, per ShellLayout.
    @Entry var splitLayout = false
}

// each window owns its workspace, created on first use so a discarded view value never builds one
private final class WorkspaceBox {
    lazy var workspace = SessionHub.shared.makeWorkspace()
}

struct ContentView: View {
    @State private var box = WorkspaceBox()
    @State private var swipes = SwipeCoordinator()
    var macs = MacManager.shared

    var body: some View {
        @Bindable var workspace = box.workspace
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
            .sceneReader { SessionHub.shared.bind(workspace, to: $0) }
            .onContinueUserActivity(SessionHub.activityType) { activity in
                guard let id = SessionHub.shared.sessionID(in: activity) else { return }
                SessionHub.shared.move(id, to: workspace)
            }
            #if targetEnvironment(simulator)
            .task { await DemoContent.presentSheets(in: workspace) }
            #endif
    }
}
