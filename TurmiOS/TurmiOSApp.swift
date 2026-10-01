import SwiftUI
import TurmCore

@main
struct TurmiOSApp: App {
    init() {
        CloudSync.shared.start()
        #if targetEnvironment(simulator)
        DemoContent.prepare()
        #endif
        MacManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands { TurmCommands() }
    }
}

struct TurmCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session") { workspace?.showsHostPicker = true }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Close Session") { workspace?.closeSelected() }
                .keyboardShortcut("w")
                .disabled(workspace?.selected == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(workspace?.sidebarHidden == true ? "Show Sidebar" : "Hide Sidebar") { workspace?.sidebarHidden.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(workspace == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") { workspace?.showsSettings = true }
                .keyboardShortcut(",")
                .disabled(workspace == nil)
        }
    }
}
