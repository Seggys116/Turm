import Foundation
import Testing
@testable import Turm

@MainActor
@Suite(.serialized)
struct ShellTabTests {
    private func makeWorkspace() -> Workspace {
        Workspace(closeCoordinator: CloseCoordinator { _ in true })
    }

    @Test func newShellIsSeparateAndActive() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let firstPane = workspace.focusedPane

        workspace.newShell()

        #expect(workspace.tabs.count == 2)
        #expect(workspace.layout.leaves.count == 1)
        #expect(workspace.focusedPane != firstPane)
        #expect(workspace.tabs[0].layout.leaves == [firstPane])
        #expect(workspace.activeTabID == workspace.tabs[1].id)
    }

    @Test func splitStaysInsideTheActiveShell() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.newShell()
        workspace.split(.horizontal)

        #expect(workspace.tabs[0].layout.leaves.count == 1)
        #expect(workspace.tabs[1].layout.leaves.count == 2)
    }

    @Test func selectingAndCyclingShells() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.newShell()
        workspace.newShell()
        let ids = workspace.tabs.map(\.id)

        workspace.selectTab(ids[0])
        #expect(workspace.activeTabID == ids[0])
        workspace.selectNextTab()
        #expect(workspace.activeTabID == ids[1])
        workspace.selectPreviousTab()
        workspace.selectPreviousTab()
        #expect(workspace.activeTabID == ids[2])
    }

    @Test func focusingAPaneActivatesItsShell() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let firstPane = workspace.focusedPane
        workspace.newShell()

        workspace.focus(firstPane)

        #expect(workspace.activeTabID == workspace.tabs[0].id)
        #expect(workspace.focusedPane == firstPane)
    }

    @Test func closingActiveShellActivatesNeighbourAndLastShellEmptiesWindow() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        var emptied = 0
        workspace.onEmpty = { emptied += 1 }
        workspace.newShell()
        workspace.newShell()
        let ids = workspace.tabs.map(\.id)

        workspace.closeTab(ids[2])
        #expect(workspace.tabs.map(\.id) == Array(ids[0...1]))
        #expect(workspace.activeTabID == ids[1])

        workspace.closeTab(ids[1])
        #expect(emptied == 0)
        workspace.closeTab(ids[0])
        #expect(workspace.openShellCount == 0)
        #expect(emptied == 1)
    }

    @Test func closingShellTerminatesAllItsPanes() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.newShell()
        workspace.split(.vertical)
        let panes = workspace.layout.leaves
        let sessions = panes.compactMap { workspace.session(for: $0) }
        #expect(sessions.count == 2)

        workspace.closeTab(workspace.activeTabID)

        #expect(workspace.tabs.count == 1)
        #expect(panes.allSatisfy { workspace.session(for: $0) == nil })
        #expect(sessions.allSatisfy { !$0.isOpen })
    }

    private func makeWorkspace(shells: Int) -> Workspace {
        let workspace = makeWorkspace()
        for _ in 1..<shells { workspace.newShell() }
        return workspace
    }

    @Test func movingFirstShellToLast() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(ids[0], to: 2)

        #expect(workspace.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func movingLastShellToFirst() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(ids[2], to: 0)

        #expect(workspace.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func movingToTheSameIndexChangesNothing() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(ids[1], to: 1)

        #expect(workspace.tabs.map(\.id) == ids)
    }

    @Test func outOfRangeIndexIsClamped() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(ids[0], to: 99)
        #expect(workspace.tabs.map(\.id) == [ids[1], ids[2], ids[0]])

        workspace.moveTab(ids[0], to: -5)
        #expect(workspace.tabs.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test func movingAnUnknownShellIsIgnored() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(UUID(), to: 0)

        #expect(workspace.tabs.map(\.id) == ids)
    }

    @Test func movingKeepsTheActiveShellAndItsLayout() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        workspace.split(.horizontal)
        let active = workspace.activeTabID
        let pane = workspace.focusedPane
        let ids = workspace.tabs.map(\.id)

        workspace.moveTab(ids[0], to: 2)

        #expect(workspace.activeTabID == active)
        #expect(workspace.focusedPane == pane)
        #expect(workspace.layout.leaves.count == 2)
    }

    private func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func newShellStartsInTheFocusedShellsDirectory() async throws {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let session = try #require(workspace.focusedSession)
        try #require(await wait { session.phase == .ready })

        session.submit("cd /usr")
        try #require(await wait { session.directory == "/usr" })
        workspace.newShell()

        #expect(workspace.focusedSession?.directory == "/usr")
    }

    @Test func openingAFolderReusesAnUntouchedShell() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let original = workspace.focusedSession

        workspace.open(directory: "/usr")

        #expect(workspace.tabs.count == 1)
        #expect(workspace.focusedSession !== original)
        #expect(original?.isOpen == false)
        #expect(workspace.focusedSession?.directory == "/usr")
    }

    @Test func openingAFolderAddsATabBesideOtherShells() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.newShell()

        workspace.open(directory: "/usr")

        #expect(workspace.tabs.count == 3)
        #expect(workspace.activeTabID == workspace.tabs[2].id)
        #expect(workspace.focusedSession?.directory == "/usr")
    }

    @Test func openingAFolderKeepsASplitShell() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.split(.horizontal)

        workspace.open(directory: "/usr")

        #expect(workspace.tabs.count == 2)
        #expect(workspace.tabs[0].layout.leaves.count == 2)
    }

    @Test func contextMenuOpensFilesInTheirFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let path = folder.standardizedFileURL.path

        #expect(ContextMenuService.directories(for: [URL(fileURLWithPath: folder.path)]) == [path])
        #expect(ContextMenuService.directories(for: [file]) == [path])
        #expect(ContextMenuService.directories(for: [folder, file]) == [path])
    }

    @Test func missingDirectoryFallsBackToHome() {
        let session = TerminalSession(directory: "/definitely/not/a/directory")
        defer { session.terminate() }
        #expect(session.directory == NSHomeDirectory())
    }

    @Test func renameSetsTrimsAndResetsTitle() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let session = workspace.focusedSession
        #expect(session?.userTitle == nil)

        session?.rename("  build box  ")
        #expect(session?.userTitle == "build box")
        #expect(session?.title == "build box")
        #expect(session?.customTitle == "build box")

        session?.rename("   ")
        #expect(session?.userTitle == nil)
        #expect(session?.customTitle == nil)
    }
}
