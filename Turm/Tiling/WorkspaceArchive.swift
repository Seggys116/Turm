import AppKit
import Foundation
import TurmCore

struct ArchivedSession: Equatable {
    var pane: PaneID
    var directory: String
    var shell: ShellKind
    var history: [String]
    var sshHostID: UUID?
    var localDirectory: String? = nil
    var remoteTarget: String? = nil
    var showsFiles: Bool
    var blocks: [SavedBlock]
}

enum WorkspaceArchive {
    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func savedNode(_ node: PaneNode) -> SavedPaneNode {
        switch node {
        case .leaf(let id):
            return .leaf(id.raw)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis == .horizontal ? .horizontal : .vertical, ratio: ratio,
                first: savedNode(first), second: savedNode(second)
            )
        }
    }

    static func paneNode(_ node: SavedPaneNode) -> PaneNode {
        switch node {
        case .leaf(let id):
            return .leaf(PaneID(raw: id))
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis == .horizontal ? .horizontal : .vertical, ratio: ratio,
                first: paneNode(first), second: paneNode(second)
            )
        }
    }

    static func capture(
        windowID: UUID, frame: SavedFrame?, tabs: [ShellTab], activeTabID: UUID, sessions: [ArchivedSession]
    ) -> SavedWindow {
        let visible = tabs.filter { !$0.isSettings }
        let known = Set(sessions.map(\.pane))
        let savedTabs = visible.compactMap { tab -> SavedTab? in
            let orphans = Set(tab.layout.leaves.filter { !known.contains($0) })
            guard let layout = tab.layout.stripping(orphans) else { return nil }
            let focused = layout.contains(tab.focusedPane) ? tab.focusedPane : layout.leaves[0]
            return SavedTab(id: tab.id, title: tab.title, layout: savedNode(layout), focusedPane: focused.raw)
        }
        guard let first = savedTabs.first else {
            return SavedWindow(id: windowID, frame: frame, tabs: [], activeTabID: activeTabID, panes: [])
        }
        let leaves = Set(savedTabs.flatMap { $0.layout.leaves })
        let panes = sessions.filter { leaves.contains($0.pane.raw) }.map { session in
            SavedPane(
                id: session.pane.raw,
                content: .shell(SavedShell(
                    directory: session.directory, shell: session.shell, history: session.history,
                    sshHostID: session.sshHostID, localDirectory: session.localDirectory, remoteTarget: session.remoteTarget
                )),
                showsFiles: session.showsFiles
            )
        }
        let active = savedTabs.contains { $0.id == activeTabID } ? activeTabID : first.id
        return SavedWindow(id: windowID, frame: frame, tabs: savedTabs, activeTabID: active, panes: panes)
    }

    static func localDirectory(for shell: SavedShell, exists: (String) -> Bool) -> (path: String, missing: Bool) {
        if shell.sshHostID != nil || shell.remoteTarget != nil {
            return (shell.localDirectory ?? "", missing: false)
        }
        return WorkingDirectory.nearestExisting(shell.directory, exists: exists)
    }

    static func session(for pane: SavedPane) -> TerminalSession {
        switch pane.content {
        case .shell(let shell):
            return make(shell, showsFiles: pane.showsFiles)
        case .diff(let diff):
            let shell = SavedShell(directory: diff.directory, shell: .zsh, history: [], sshHostID: diff.sshHostID)
            return make(shell, showsFiles: pane.showsFiles)
        }
    }

    private static func make(_ shell: SavedShell, showsFiles: Bool) -> TerminalSession {
        let session: TerminalSession
        if shell.sshHostID != nil || shell.remoteTarget != nil {
            session = TerminalSession(
                directory: shell.localDirectory ?? NSHomeDirectory(),
                restoredHost: shell.sshHostID,
                restoredTarget: shell.remoteTarget.flatMap(SSHTarget.init(identifier:)),
                remoteDirectory: shell.directory
            )
        } else {
            let resolved = WorkingDirectory.nearestExisting(shell.directory) { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            session = TerminalSession(directory: resolved.path)
            if resolved.missing {
                session.restoreNotice = "Opened \(resolved.path) because \(shell.directory) is gone."
            }
        }
        session.showsFiles = showsFiles
        session.history.restore(shell.history)
        return session
    }
}

enum WorkspacePersistence {
    static let restoreKey = "turm.restoreWorkspace"
    static let skipOnceKey = "turm.skipWorkspaceRestoreOnce"

    private(set) static var isQuitting = false
    private static var consumedLaunch = false
    static var storeOverride: WorkspaceStore?

    static var allowsDiskOverride: Bool?
    static var allowsDisk: Bool {
        if let allowsDiskOverride { return allowsDiskOverride }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] == nil && environment["XCTestSessionIdentifier"] == nil
    }

    static func store() -> WorkspaceStore {
        if let storeOverride { return storeOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return WorkspaceStore(root: support.appendingPathComponent("Turm/Workspace", isDirectory: true))
    }

    static func restoreEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: restoreKey) == nil { return true }
        return defaults.bool(forKey: restoreKey)
    }

    static func setRestoreEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: restoreKey)
    }

    static func shouldRestore(defaults: UserDefaults = .standard) -> Bool {
        let decision = RestoreLaunch.decide(
            restoreEnabled: restoreEnabled(defaults: defaults), skipOnce: defaults.bool(forKey: skipOnceKey)
        )
        if decision.clearSkipOnce { defaults.removeObject(forKey: skipOnceKey) }
        return decision.restore
    }

    static func savesOnClose(otherVisibleMainWindows: Int) -> Bool {
        isQuitting || otherVisibleMainWindows == 0
    }

    static func prepareToQuit() {
        isQuitting = true
    }

    static func cancelQuit() {
        isQuitting = false
    }

    static func save(_ workspace: Workspace, force: Bool = false) {
        guard !workspace.didTerminate else { return }
        guard force || (allowsDisk && workspace.persistsToDisk) else { return }
        let captured = workspace.captureWindow()
        var document = (try? store().load()) ?? WorkspaceDocument(windows: [], keyWindowID: nil)
        if let index = document.windows.firstIndex(where: { $0.id == captured.id }) {
            document.windows[index] = captured
        } else {
            document.windows.append(captured)
        }
        if workspace.savedIsKey || document.keyWindowID == nil {
            document.keyWindowID = captured.id
        }
        try? store().save(document)
        for session in workspace.archivedSessions() {
            try? store().save(session.blocks, for: session.pane.raw)
        }
    }

    static func saveBlocks(of workspace: Workspace) {
        guard allowsDisk, workspace.persistsToDisk else { return }
        for session in workspace.archivedSessions() {
            try? store().save(session.blocks, for: session.pane.raw)
        }
    }

    static func saveRegistered(_ workspaces: [Workspace]) {
        workspaces.forEach { save($0) }
    }

    static func remove(_ workspace: Workspace) {
        guard allowsDisk, workspace.persistsToDisk else { return }
        try? store().removeWindow(workspace.windowID)
    }

    static func clear() {
        guard allowsDisk else { return }
        try? store().clear()
    }

    static func takeLaunchWindow() -> SavedWindow? {
        guard allowsDisk else { return nil }
        if consumedLaunch { return nil }
        consumedLaunch = true
        guard shouldRestore(), let document = try? store().load() else { return nil }
        if let key = document.keyWindowID, let window = document.windows.first(where: { $0.id == key }) {
            return window
        }
        return document.windows.first
    }

    static func resetForTests() {
        consumedLaunch = false
        isQuitting = false
        storeOverride = nil
        allowsDiskOverride = nil
    }
}
