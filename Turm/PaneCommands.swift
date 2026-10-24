import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
    @Entry var spaces: SpaceActions?
}

struct PaneCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.spotlightPresented) private var spotlight
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @FocusedValue(\.spaces) private var spaces

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .sidebar) {
            Button(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(ChromeMetrics.motion) { isSidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
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
            Button("Search") { spotlight?.wrappedValue = true }
                .keyboardShortcut("t")
            Button("New Shell") { workspace?.newShell() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("New Space") { spaces?.newSpace() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Open Space in New Window") { spaces?.openCurrentInNewWindow() }
            Button("Next Space") { spaces?.nextSpace() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Space") { spaces?.previousSpace() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(workspace?.focusedSession?.showsFiles == true ? "Hide Files" : "Show Files") {
                workspace?.focusedSession?.showsFiles.toggle()
            }
            Button("Next Shell") { workspace?.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Shell") { workspace?.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Split Right") { workspace?.split(.horizontal) }
                .keyboardShortcut("d")
            Button("Split Down") { workspace?.split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Even Out Panes") { workspace?.equalizePanes() }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled((workspace?.layout.leaves.count ?? 0) < 2)
            Button("Move Pane to New Shell") { workspace.map { $0.breakOut($0.focusedPane) } }
                .disabled(!(workspace.map { $0.canBreakOut($0.focusedPane) } ?? false))
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
