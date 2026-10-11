import Foundation
import Testing
import TurmCore
@testable import Turm

// Workspace restore coverage for directories and remote shells.
@Suite(.serialized)
struct WorkspaceArchiveTests {
    @Test func captureKeepsANestedSplitAndTheFocusedPane() {
        let left = PaneID()
        let right = PaneID()
        let bottom = PaneID()
        let horizontal = UUID()
        let vertical = UUID()
        let layout = PaneNode.split(
            id: vertical, axis: .vertical, ratio: 0.25,
            first: .split(id: horizontal, axis: .horizontal, ratio: 0.4, first: .leaf(left), second: .leaf(right)),
            second: .leaf(bottom)
        )
        let tab = ShellTab(layout: layout, focusedPane: right, title: "Build")
        let sessions = [left, right, bottom].map {
            ArchivedSession(
                pane: $0, directory: "/work", shell: .zsh, history: ["ls"], sshHostID: $0 == bottom ? UUID() : nil,
                showsFiles: $0 == left, blocks: []
            )
        }
        let saved = WorkspaceArchive.capture(
            windowID: UUID(), frame: SavedFrame(x: 1, y: 2, width: 3, height: 4), tabs: [tab], activeTabID: tab.id, sessions: sessions
        )
        #expect(saved.tabs.count == 1)
        #expect(saved.tabs[0].focusedPane == right.raw)
        #expect(saved.tabs[0].title == "Build")
        #expect(saved.frame == SavedFrame(x: 1, y: 2, width: 3, height: 4))
        let restored = WorkspaceArchive.paneNode(saved.tabs[0].layout)
        #expect(restored == layout)
        #expect(saved.panes.first { $0.id == left.raw }?.showsFiles == true)
        #expect(saved.panes.first { $0.id == bottom.raw }?.content == .shell(SavedShell(
            directory: "/work", shell: .zsh, history: ["ls"], sshHostID: sessions[2].sshHostID
        )))
    }

    @Test func localDirectoryWalksToAParentAndLeavesAnSSHPathAlone() {
        let missing = WorkingDirectory.nearestExisting("/gone/child") { $0 == "/gone" }
        let shell = SavedShell(directory: "/gone/child", shell: .bash, history: [])
        let resolved = WorkspaceArchive.localDirectory(for: shell) { $0 == "/gone" }
        #expect(resolved.path == missing.path)
        #expect(resolved.missing)
        let remote = SavedShell(directory: "/srv/app", shell: .zsh, history: [], sshHostID: UUID())
        let ssh = WorkspaceArchive.localDirectory(for: remote) { _ in true }
        #expect(ssh.path.isEmpty)
        #expect(!ssh.missing)
    }

    @Test func restoreEnabledDefaultsOn() {
        let suite = "turm.restore.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkspacePersistence.restoreEnabled(defaults: defaults))
        WorkspacePersistence.setRestoreEnabled(false, defaults: defaults)
        #expect(!WorkspacePersistence.restoreEnabled(defaults: defaults))
    }

    @Test func closingTheLastWindowKeepsTheWorkspace() {
        WorkspacePersistence.cancelQuit()
        #expect(WorkspacePersistence.savesOnClose(otherVisibleMainWindows: 0))
        #expect(!WorkspacePersistence.savesOnClose(otherVisibleMainWindows: 1))
        WorkspacePersistence.prepareToQuit()
        #expect(WorkspacePersistence.savesOnClose(otherVisibleMainWindows: 2))
        WorkspacePersistence.cancelQuit()
    }

    @Test func saveRoundTripsTheOpenWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-archive-" + UUID().uuidString, isDirectory: true)
        WorkspacePersistence.storeOverride = WorkspaceStore(root: root)
        defer {
            WorkspacePersistence.resetForTests()
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = CloseCoordinator { _ in true }
        let workspace = Workspace(closeCoordinator: coordinator)
        defer { workspace.terminateAll() }
        workspace.split(.horizontal)
        let saved = workspace.captureWindow()
        WorkspacePersistence.save(workspace, force: true)
        let loaded = try #require(try WorkspacePersistence.store().load())
        #expect(loaded.windows.map(\.id) == [workspace.windowID])
        #expect(loaded.windows[0].tabs[0].layout.leaves.count == saved.tabs[0].layout.leaves.count)
        #expect(loaded.keyWindowID == workspace.windowID)
    }

    @Test func quittingAfterTheShellsStopDoesNotEraseTheSavedWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-archive-" + UUID().uuidString, isDirectory: true)
        WorkspacePersistence.storeOverride = WorkspaceStore(root: root)
        WorkspacePersistence.allowsDiskOverride = true
        defer {
            WorkspacePersistence.resetForTests()
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = Workspace(closeCoordinator: CloseCoordinator { _ in true })
        WorkspacePersistence.save(workspace, force: true)
        let saved = try #require(try WorkspacePersistence.store().load())
        let paneCount = saved.windows[0].panes.count
        #expect(paneCount > 0)
        workspace.terminateAll()
        WorkspacePersistence.save(workspace, force: true)
        let loaded = try #require(try WorkspacePersistence.store().load())
        #expect(loaded.windows[0].panes.count == paneCount)
        #expect(loaded.windows[0].tabs.count == saved.windows[0].tabs.count)
    }

    @Test func restoringAnSSHPaneDoesNotUseTheRemotePath() {
        let host = UUID()
        let pane = UUID()
        let tab = UUID()
        let window = SavedWindow(
            id: UUID(), frame: nil,
            tabs: [SavedTab(id: tab, title: nil, layout: .leaf(pane), focusedPane: pane)],
            activeTabID: tab,
            panes: [SavedPane(
                id: pane,
                content: .shell(SavedShell(directory: "/remote/only", shell: .fish, history: ["make"], sshHostID: host)),
                showsFiles: true
            )]
        )
        let coordinator = CloseCoordinator { _ in true }
        let workspace = Workspace(restoring: window, closeCoordinator: coordinator)
        defer { workspace.terminateAll() }
        let session = workspace.session(for: PaneID(raw: pane))
        #expect(session?.restoredHostID == host)
        #expect(session?.directory == "/remote/only")
        #expect(session?.localDirectory != "/remote/only")
        #expect(session?.isRemote == true)
        #expect(session?.restoreNotice == "Reconnecting…")
        #expect(session?.showsFiles == true)
        #expect(session?.history.entries == ["make"])
    }

    @Test func restoringAnUnsavedRemoteRemembersTheTargetAndDirectory() {
        let pane = UUID()
        let tab = UUID()
        let window = SavedWindow(
            id: UUID(), frame: nil,
            tabs: [SavedTab(id: tab, title: nil, layout: .leaf(pane), focusedPane: pane)],
            activeTabID: tab,
            panes: [SavedPane(
                id: pane,
                content: .shell(SavedShell(
                    directory: "/home/zak", shell: .zsh, history: [],
                    localDirectory: NSHomeDirectory(), remoteTarget: "zak@example.com:22"
                ))
            )]
        )
        let workspace = Workspace(restoring: window, closeCoordinator: CloseCoordinator { _ in true })
        defer { workspace.terminateAll() }
        let session = workspace.session(for: PaneID(raw: pane))
        #expect(session?.directory == "/home/zak")
        #expect(session?.localDirectory == NSHomeDirectory())
        #expect(session?.restoredTarget == SSHTarget(user: "zak", hostname: "example.com", port: 22))
        #expect(session?.isRemote == true)
        #expect(session?.location.hasSuffix(":/home/zak") == true)
    }

    @Test func aMissingFolderFallsBackAndADiffIsRemembered() {
        let pane = UUID()
        let tab = UUID()
        let missing = "/no/such/turm/folder/" + UUID().uuidString
        let diff = SavedDiff(directory: NSHomeDirectory(), scope: .staged, layout: .sideBySide, sshHostID: nil)
        let window = SavedWindow(
            id: UUID(), frame: nil,
            tabs: [SavedTab(id: tab, title: nil, layout: .leaf(pane), focusedPane: pane)],
            activeTabID: tab,
            panes: [SavedPane(id: pane, content: .diff(diff))]
        )
        let coordinator = CloseCoordinator { _ in true }
        let workspace = Workspace(restoring: window, closeCoordinator: coordinator)
        defer { workspace.terminateAll() }
        #expect(workspace.restoredDiffs[PaneID(raw: pane)] == diff)
        let session = workspace.session(for: PaneID(raw: pane))
        #expect(session?.directory != missing)
        #expect(session?.restoreNotice == nil)
    }

    @Test func aPaneWithNoSavedShellDoesNotComeBackBlank() {
        let shell = UUID()
        let orphan = UUID()
        let tab = UUID()
        let window = SavedWindow(
            id: UUID(), frame: nil,
            tabs: [SavedTab(
                id: tab, title: nil,
                layout: .split(
                    id: UUID(), axis: .horizontal, ratio: 0.5,
                    first: .leaf(shell), second: .leaf(orphan)
                ),
                focusedPane: orphan
            )],
            activeTabID: tab,
            panes: [SavedPane(
                id: shell,
                content: .shell(SavedShell(directory: NSHomeDirectory(), shell: .zsh, history: [])),
                showsFiles: false
            )]
        )
        let workspace = Workspace(restoring: window, closeCoordinator: CloseCoordinator { _ in true })
        defer { workspace.terminateAll() }
        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs[0].layout.leaves == [PaneID(raw: shell)])
        #expect(workspace.session(for: PaneID(raw: shell)) != nil)
        #expect(workspace.focusedPane == PaneID(raw: shell))
    }

    @Test func shuttingDownDoesNotSaveTheLayoutWithoutItsShells() {
        let coordinator = CloseCoordinator { _ in true }
        let workspace = Workspace(closeCoordinator: coordinator)
        let pane = workspace.focusedPane
        workspace.terminateAll()
        let saved = workspace.captureWindow()
        #expect(saved.panes.isEmpty)
        #expect(saved.tabs.allSatisfy { !$0.layout.leaves.contains(pane.raw) })
    }
}
