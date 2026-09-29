import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct PaneCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {}
        CommandMenu("Shell") {
            Button("Split Right") { workspace?.split(.horizontal) }
                .keyboardShortcut("d")
            Button("Split Down") { workspace?.split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Next Pane") { workspace?.focusNext() }
                .keyboardShortcut("]")
            Button("Previous Pane") { workspace?.focusPrevious() }
                .keyboardShortcut("[")
            Divider()
            Button("Close Pane") { workspace?.closeFocused() }
                .keyboardShortcut("w")
        }
    }
}
