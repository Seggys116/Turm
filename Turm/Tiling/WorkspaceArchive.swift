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
        return !isRunningTests
    }

    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil || environment["XCTestBundlePath"] != nil { return true }
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing-helper")
            || NSClassFromString("XCTestCase") != nil
    }()

    private static let testStoreRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("turm-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func store() -> WorkspaceStore {
        if let storeOverride { return storeOverride }
        if isRunningTests { return WorkspaceStore(root: testStoreRoot) }
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

    private static var activeWriter: WorkspaceWriter?
    private static var ledger = BlockWriteLedger()

    private static func writer() -> WorkspaceWriter {
        let current = store()
        if let activeWriter, activeWriter.store.root == current.root { return activeWriter }
        activeWriter?.drain()
        ledger.reset()
        let next = WorkspaceWriter(store: current)
        activeWriter = next
        return next
    }

    static func save(_ workspace: Workspace, force: Bool = false) {
        workspace.cancelPendingSave()
        write(workspace, force: force, layout: true, wait: true)
    }

    static func flush(_ workspace: Workspace, _ batch: SaveTracker.Batch) {
        write(workspace, force: false, layout: batch.layout, wait: false)
    }

    private static func write(_ workspace: Workspace, force: Bool, layout: Bool, wait: Bool) {
        guard !workspace.didTerminate else { return }
        guard force || (allowsDisk && workspace.persistsToDisk) else { return }
        let writer = writer()
        if workspace.isTemporarySpace {
            guard layout, allowsDisk else { return }
            let ids = Set([workspace.windowID, workspace.spaceID].compactMap { $0 })
            writer.update(wait: wait) { $0.purgeScratch(ids: ids) }
            return
        }
        let changed = ledger.claim(workspace.blockSignatures())
        var blocks: [UUID: [SavedBlock]] = [:]
        if !changed.isEmpty {
            for session in workspace.archivedSessions(blocksFor: changed) where changed.contains(session.pane.raw) {
                blocks[session.pane.raw] = session.blocks
            }
        }
        guard layout else {
            writer.update(wait: wait, blocks: blocks)
            return
        }
        let captured = workspace.captureWindow()
        let isKey = workspace.savedIsKey
        let space = workspace.spaceID.map { id in
            SavedSpace(
                id: id, name: workspace.spaceName, symbol: workspace.spaceSymbol, session: captured,
                isTemporary: workspace.isTemporarySpace
            )
        }
        writer.update(wait: wait, createIfMissing: true, blocks: blocks) { document in
            document.record(captured, isKey: isKey, space: space)
            return true
        }
    }

    static func saveRegistered(_ workspaces: [Workspace]) {
        workspaces.forEach { save($0) }
    }

    static func remove(_ workspace: Workspace) {
        guard allowsDisk, workspace.persistsToDisk else { return }
        let id = workspace.windowID
        writer().update(wait: true) { document in
            document = document.removingWindow(id)
            return true
        }
    }

    static func removeSpace(_ id: UUID) {
        guard allowsDisk else { return }
        writer().update(wait: true) { document in
            document = document.removingWindow(id)
            document.spaces.removeAll { $0.id == id || $0.session.id == id }
            if document.keyWindowID == id { document.keyWindowID = document.spaces.first?.id ?? document.windows.first?.id }
            return true
        }
    }

    static func renameSpace(_ id: UUID, to name: String) {
        guard allowsDisk else { return }
        writer().update(wait: true) { document in
            guard let index = document.spaces.firstIndex(where: { $0.id == id }) else { return false }
            document.spaces[index].name = name
            return true
        }
    }

    static func setSpaceSymbol(_ id: UUID, to symbol: String) {
        guard allowsDisk else { return }
        writer().update(wait: true) { document in
            guard let index = document.spaces.firstIndex(where: { $0.id == id }) else { return false }
            document.spaces[index].symbol = symbol
            return true
        }
    }

    static func consumeLaunchDocument() -> WorkspaceDocument? {
        guard allowsDisk else { return nil }
        if consumedLaunch { return nil }
        consumedLaunch = true
        guard shouldRestore(), let document = try? store().load() else { return nil }
        return document
    }

    static func clear() {
        guard allowsDisk else { return }
        CloseCoordinator.shared.registeredWorkspaces.forEach { $0.cancelPendingSave() }
        ledger.reset()
        writer().clear()
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
        activeWriter?.drain()
        activeWriter = nil
        ledger.reset()
    }
}
