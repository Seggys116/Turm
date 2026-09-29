import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct PaneCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.spotlightPresented) private var spotlight
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarPlacement.key) private var placement = SidebarPlacement.left

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .sidebar) {
            Button(isSidebarVisible ? "Hide \(placement.noun)" : "Show \(placement.noun)") {
                withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Picker("Sidebar Position", selection: $placement.animation(.easeInOut(duration: 0.18))) {
                ForEach(SidebarPlacement.allCases) { Text($0.title).tag($0) }
            }
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find...") { workspace?.focusedSession?.search.present() }
                    .keyboardShortcut("f")
                Button("Find Next") { workspace?.focusedSession?.search.next() }
                    .keyboardShortcut("g")
                Button("Find Previous") { workspace?.focusedSession?.search.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { useSelectionForFind() }
                    .keyboardShortcut("e")
            }
            .disabled(workspace?.focusedSession == nil)
        }
        CommandMenu("Shell") {
            Button("Spotlight") { spotlight?.wrappedValue = true }
                .keyboardShortcut("t")
            Button("New Shell") { workspace?.newShell() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Next Shell") { workspace?.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Shell") { workspace?.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
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

    private var editorSelection: NSTextView? {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.selectedRange().length > 0 else { return nil }
        return view
    }

    private func useSelectionForFind() {
        guard let session = workspace?.focusedSession else { return }
        if let view = editorSelection {
            session.search.useSelection((view.string as NSString).substring(with: view.selectedRange()))
        } else if let text = session.selection.selectedText() {
            session.search.useSelection(text)
        }
    }
}
