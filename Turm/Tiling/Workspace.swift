import Foundation
import Observation
import TurmCore

nonisolated enum TileItem: Equatable, Sendable {
    case tab(UUID)
    case pane(PaneID)
}

nonisolated struct ShellTab: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var layout: PaneNode
    var focusedPane: PaneID
    var isSettings: Bool
    var title: String?

    init(id: UUID = UUID(), layout: PaneNode, focusedPane: PaneID, isSettings: Bool = false, title: String? = nil) {
        self.id = id
        self.layout = layout
        self.focusedPane = focusedPane
        self.isSettings = isSettings
        self.title = title
    }
}

struct ShellTransfer {
    let layout: PaneNode
    let focusedPane: PaneID
    let title: String?
    let sessions: [PaneID: TerminalSession]
    var viewers: [PaneID: ViewerPane] = [:]
}

enum ViewerPane: Equatable {
    case diff(shell: PaneID, staged: Bool)
    case file(path: String)
    case remoteFile(shell: PaneID, path: String)

    var title: String {
        switch self {
        case .diff(_, let staged): staged ? "Staged diff" : "Diff"
        case .file(let path): (path as NSString).lastPathComponent
        case .remoteFile(_, let path): (path as NSString).lastPathComponent
        }
    }

    var symbol: String {
        switch self {
        case .diff: "plus.forwardslash.minus"
        case .file, .remoteFile: "doc.text"
        }
    }
}

@Observable
final class Workspace {
    private(set) var tabs: [ShellTab] {
        didSet { persistLayout() }
    }
    private(set) var activeTabID: UUID {
        didSet {
            guard oldValue != activeTabID else { return }
            recentTabs.removeAll { $0 == oldValue || $0 == activeTabID }
            recentTabs.insert(oldValue, at: 0)
        }
    }
    private var recentTabs: [UUID] = []
    private var sessions: [PaneID: TerminalSession] = [:]
    private let closeCoordinator: CloseCoordinator
    let windowID: UUID
    var spaceID: UUID?
    var spaceName = "Space"
    var spaceSymbol = "terminal"
    var isTemporarySpace = false
    var restoredDiffs: [PaneID: SavedDiff] = [:]
    var viewers: [PaneID: ViewerPane] = [:]
    private(set) var savedFrame: SavedFrame?
    private(set) var savedIsKey = false
    private(set) var didTerminate = false

    var onEmpty: () -> Void = {}

    var persistsToDisk: Bool { closeCoordinator === CloseCoordinator.shared }

    init(closeCoordinator: CloseCoordinator = .shared, transfer: ShellTransfer? = nil) {
        self.closeCoordinator = closeCoordinator
        self.windowID = UUID()
        if let transfer {
            let tab = ShellTab(layout: transfer.layout, focusedPane: transfer.focusedPane, title: transfer.title)
            tabs = [tab]
            activeTabID = tab.id
            transfer.sessions.forEach { bind($1, to: $0) }
            transfer.viewers.forEach { viewers[$0.key] = $0.value }
        } else {
            let first = PaneID()
            let tab = ShellTab(layout: .leaf(first), focusedPane: first)
            tabs = [tab]
            activeTabID = tab.id
            sessions[first] = makeSession(for: first)
        }
        closeCoordinator.register(self)
    }

    init(restoring window: SavedWindow, closeCoordinator: CloseCoordinator = .shared) {
        self.closeCoordinator = closeCoordinator
        self.windowID = window.id
        var built: [ShellTab] = []
        var diffs: [PaneID: SavedDiff] = [:]
        var created: [PaneID: TerminalSession] = [:]
        let known = Set(window.panes.map { PaneID(raw: $0.id) })
        for tab in window.tabs {
            let full = WorkspaceArchive.paneNode(tab.layout)
            guard let layout = full.stripping(Set(full.leaves.filter { !known.contains($0) })) else { continue }
            let focused = PaneID(raw: tab.focusedPane)
            let resolved = layout.contains(focused) ? focused : (layout.leaves.first ?? focused)
            built.append(ShellTab(id: tab.id, layout: layout, focusedPane: resolved, title: tab.title))
            for pane in window.panes where layout.leaves.contains(PaneID(raw: pane.id)) {
                let id = PaneID(raw: pane.id)
                guard created[id] == nil else { continue }
                created[id] = WorkspaceArchive.session(for: pane)
                if case .diff(let diff) = pane.content { diffs[id] = diff }
            }
        }
        if built.isEmpty {
            let first = PaneID()
            built = [ShellTab(layout: .leaf(first), focusedPane: first)]
            created[first] = TerminalSession()
        }
        self.tabs = built
        self.activeTabID = built.first { $0.id == window.activeTabID }?.id ?? built[0].id
        self.restoredDiffs = diffs
        self.savedFrame = window.frame
        closeCoordinator.register(self)
        created.forEach { bind($1, to: $0) }
    }

    func noteFrame(_ rect: NSRect, isKey: Bool) {
        savedFrame = SavedFrame(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        savedIsKey = isKey
    }

    func releaseKey() {
        savedIsKey = false
    }

    func claimKey() {
        savedIsKey = true
    }

    func captureWindow() -> SavedWindow {
        let hidden = Set(viewers.keys)
        let visible = tabs.compactMap { tab -> ShellTab? in
            guard let layout = tab.layout.stripping(hidden) else { return nil }
            var copy = tab
            copy.layout = layout
            if !layout.contains(copy.focusedPane), let first = layout.leaves.first {
                copy.focusedPane = first
            }
            return copy
        }
        let saving = visible
        let active = saving.contains { $0.id == activeTabID } ? activeTabID : (saving.first?.id ?? activeTabID)
        return WorkspaceArchive.capture(
            windowID: windowID, frame: savedFrame, tabs: saving, activeTabID: active, sessions: archivedSessions()
        )
    }

    func archivedSessions() -> [ArchivedSession] {
        sessionEntries.map { pane, session in
            let hostID = session.restoredHostID ?? session.connection?.host?.id
            let target = session.remoteTarget ?? session.restoredTarget
            let remote = session.isRemote || hostID != nil || target != nil
            let directory: String
            let sshHostID: UUID?
            let localDirectory: String?
            let remoteTarget: String?
            if remote {
                directory = session.directory
                sshHostID = hostID
                localDirectory = session.localDirectory
                remoteTarget = target?.identifier
            } else {
                directory = session.directory
                sshHostID = nil
                localDirectory = nil
                remoteTarget = nil
            }
            let blocks = session.blocks.filter { !$0.isRunning }.map { block in
                SavedBlock(
                    id: block.id, command: block.command, directory: block.directory, gitBranch: block.git?.branch,
                    host: block.host, exitCode: block.exitCode, duration: block.duration.map(WorkspaceArchive.seconds),
                    output: block.plainOutput
                )
            }
            return ArchivedSession(
                pane: pane, directory: directory, shell: session.archiveShell, history: BlockArchive.cappedHistory(session.history.entries),
                sshHostID: sshHostID, localDirectory: localDirectory, remoteTarget: remoteTarget,
                showsFiles: session.showsFiles, blocks: blocks
            )
        }
    }

    private func persistLayout() {
        guard !didTerminate else { return }
        WorkspacePersistence.save(self)
    }

    private func persistBlocks() {
        guard !didTerminate else { return }
        WorkspacePersistence.saveBlocks(of: self)
    }

    deinit {
        didTerminate = true
        sessions.values.forEach { $0.terminate() }
    }

    var layout: PaneNode {
        tabs[activeIndex].layout
    }

    var focusedPane: PaneID {
        tabs[activeIndex].focusedPane
    }

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    func session(for pane: PaneID) -> TerminalSession? {
        sessions[pane]
    }

    var focusedTitle: String {
        if tabs[activeIndex].isSettings { return "Settings" }
        return sessions[focusedPane]?.title ?? "Turm"
    }

    var focusedSession: TerminalSession? {
        sessions[focusedPane]
    }

    var openShellCount: Int {
        sessions.values.filter(\.isOpen).count
    }

    var shellsRequiringConfirmationCount: Int {
        sessions.values.filter { $0.isOpen && ($0.hasSubmittedCommand || $0.isRunningAction) }.count
    }

    func shouldCloseWindow() -> Bool {
        let count = shellsRequiringConfirmationCount
        return count == 0 || closeCoordinator.confirm(.window(shellCount: count))
    }

    func terminateAll() {
        guard !didTerminate else { return }
        didTerminate = true
        let closing = Array(sessions.values)
        sessions.removeAll()
        for session in closing {
            session.onLayoutChange = {}
            session.onBlockFinished = {}
            session.onExit = {}
            session.onFocus = {}
            session.onPopOut = { _ in }
            session.terminate()
        }
    }

    func split(_ axis: SplitAxis) {
        guard !tabs[activeIndex].isSettings else { return }
        let newPane = PaneID()
        sessions[newPane] = makeSession(for: newPane, directory: focusedSession?.launchDirectory)
        let index = activeIndex
        tabs[index].layout = tabs[index].layout.splitting(tabs[index].focusedPane, axis: axis, inserting: newPane)
        tabs[index].focusedPane = newPane
    }

    func newShell(directory: String? = nil, command: String? = nil) {
        let pane = PaneID()
        let session = makeSession(for: pane, directory: directory ?? focusedSession?.launchDirectory)
        sessions[pane] = session
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.submitWhenReady(command) }
        let tab = ShellTab(layout: .leaf(pane), focusedPane: pane)
        tabs.insert(tab, at: activeIndex + 1)
        activeTabID = tab.id
    }

    func open(directory: String) {
        let index = activeIndex
        guard tabs.count == 1, !tabs[index].isSettings, case .leaf(let pane) = tabs[index].layout,
              let current = sessions[pane], !current.hasSubmittedCommand, !current.isRunningAction
        else {
            newShell(directory: directory)
            return
        }
        let replacement = PaneID()
        sessions[replacement] = makeSession(for: replacement, directory: directory)
        tabs[index].layout = .leaf(replacement)
        tabs[index].focusedPane = replacement
        sessions.removeValue(forKey: pane)
        current.terminate()
    }

    func openSettings() {
        if let existing = tabs.first(where: \.isSettings) {
            activeTabID = existing.id
            return
        }
        let pane = PaneID()
        let tab = ShellTab(layout: .leaf(pane), focusedPane: pane, isSettings: true)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func selectNextTab() {
        moveTab(by: 1)
    }

    func selectPreviousTab() {
        moveTab(by: -1)
    }

    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index, 0), tabs.count - 1)
        guard target != from else { return }
        tabs.insert(tabs.remove(at: from), at: target)
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isSettings {
            let sessionPanes = tab.layout.leaves.filter { sessions[$0] != nil }
            sessionPanes.compactMap { sessions.removeValue(forKey: $0) }.forEach { $0.terminate() }
            if let index = tabs.firstIndex(where: { $0.id == id }) { removeTab(at: index) }
            return
        }
        let panes = tab.layout.leaves
        let needsConfirmation = panes.contains { sessions[$0]?.needsCloseConfirmation ?? false }
        if needsConfirmation, !closeCoordinator.confirm(.shell) { return }
        panes.forEach(removePane)
    }

    var sessionEntries: [(pane: PaneID, session: TerminalSession)] {
        sessions.map { (pane: $0.key, session: $0.value) }
    }

    func closeRemotely(_ pane: PaneID, force: Bool) -> Bool {
        guard let session = sessions[pane] else { return false }
        if session.needsCloseConfirmation, !force { return false }
        removePane(pane)
        return true
    }

    func close(_ pane: PaneID) {
        if viewers[pane] != nil {
            viewers[pane] = nil
            lift(pane)
            return
        }
        guard let session = sessions[pane] else { return }
        if session.needsCloseConfirmation, !closeCoordinator.confirm(.shell) { return }
        removePane(pane)
    }

    func openDiff(from session: TerminalSession, staged: Bool) {
        guard let pane = sessions.first(where: { $0.value === session })?.key else { return }
        openViewer(.diff(shell: pane, staged: staged), beside: pane)
    }

    func openFile(_ path: String) {
        guard tabs.contains(where: { $0.layout.contains(focusedPane) }), !tabs[activeIndex].isSettings else { return }
        openViewer(.file(path: path), beside: focusedPane)
    }

    func openRemoteFile(_ path: String, from session: TerminalSession) {
        guard let pane = sessions.first(where: { $0.value === session })?.key else { return }
        openViewer(.remoteFile(shell: pane, path: path), beside: pane)
    }

    private func openViewer(_ viewer: ViewerPane, beside pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }), !tabs[index].isSettings else { return }
        let id = PaneID()
        viewers[id] = viewer
        tabs[index].layout = tabs[index].layout.splitting(pane, axis: .horizontal, inserting: id)
        tabs[index].focusedPane = id
        if tabs[index].id != activeTabID { activeTabID = tabs[index].id }
    }

    private func removePane(_ pane: PaneID) {
        guard sessions[pane] != nil, tabs.contains(where: { $0.layout.contains(pane) }) else { return }
        sessions.removeValue(forKey: pane)?.terminate()
        lift(pane)
    }

    private func lift(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }) else { return }
        let order = tabs[index].layout.leaves
        guard let remaining = tabs[index].layout.removing(pane) else {
            removeTab(at: index)
            return
        }
        tabs[index].layout = remaining
        if tabs[index].focusedPane == pane, let position = order.firstIndex(of: pane) {
            tabs[index].focusedPane = remaining.leaves[max(position - 1, 0)]
        }
    }

    func lastActiveShell(before id: UUID) -> UUID? {
        recentTabs.first { recent in recent != id && tabs.contains { $0.id == recent && !$0.isSettings } }
    }

    func renameTab(_ id: UUID, to text: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].title = trimmed.isEmpty ? nil : trimmed
    }

    func canTearOff(_ item: TileItem) -> Bool {
        switch item {
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }), !tab.isSettings else { return false }
            return tabs.count > 1
        case .pane(let pane):
            guard owns(pane) else { return false }
            return tabs.count > 1 || canBreakOut(pane)
        }
    }

    func release(_ item: TileItem) -> ShellTransfer? {
        let tab: ShellTab
        switch item {
        case .tab(let id):
            guard let found = tabs.first(where: { $0.id == id }), !found.isSettings else { return nil }
            tab = found
        case .pane(let pane):
            guard owns(pane) else { return nil }
            tab = ShellTab(layout: .leaf(pane), focusedPane: pane)
        }
        var moved: [PaneID: TerminalSession] = [:]
        var movedViewers: [PaneID: ViewerPane] = [:]
        for pane in tab.layout.leaves {
            if let session = sessions.removeValue(forKey: pane) { moved[pane] = session }
            if let viewer = viewers.removeValue(forKey: pane) { movedViewers[pane] = viewer }
        }
        tab.layout.leaves.forEach(lift)
        return ShellTransfer(layout: tab.layout, focusedPane: tab.focusedPane, title: tab.title, sessions: moved, viewers: movedViewers)
    }

    func receive(_ transfer: ShellTransfer) {
        transfer.sessions.forEach { bind($1, to: $0) }
        transfer.viewers.forEach { viewers[$0.key] = $0.value }
        let tab = ShellTab(layout: transfer.layout, focusedPane: transfer.focusedPane, title: transfer.title)
        tabs.insert(tab, at: activeIndex + 1)
        activeTabID = tab.id
    }

    func tab(containing pane: PaneID) -> ShellTab? {
        tabs.first { $0.layout.contains(pane) }
    }

    func canDrop(_ item: TileItem, on drop: PaneDrop) -> Bool {
        let active = tabs[activeIndex]
        guard !active.isSettings else { return false }
        if case .pane(let target) = drop.anchor, !active.layout.contains(target) { return false }
        switch item {
        case .tab(let id):
            guard id != active.id, let tab = tabs.first(where: { $0.id == id }) else { return false }
            return !tab.isSettings && drop.edge != nil
        case .pane(let pane):
            guard owns(pane), drop.anchor != .pane(pane) else { return false }
            if active.layout.contains(pane) { return active.layout.leaves.count > 1 }
            return drop.edge != nil
        }
    }

    func drop(_ item: TileItem, on drop: PaneDrop) {
        guard canDrop(item, on: drop) else { return }
        let activeID = activeTabID
        switch item {
        case .tab(let id):
            guard let source = tabs.firstIndex(where: { $0.id == id }), let edge = drop.edge else { return }
            let moved = tabs.remove(at: source)
            guard let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
            tabs[index].layout = tabs[index].layout.inserting(moved.layout, at: drop.anchor, edge: edge)
            tabs[index].focusedPane = moved.focusedPane
        case .pane(let pane):
            if tabs[activeIndex].layout.contains(pane) {
                let index = activeIndex
                if let edge = drop.edge {
                    tabs[index].layout = tabs[index].layout.moving(pane, to: drop.anchor, edge: edge)
                } else if case .pane(let target) = drop.anchor {
                    tabs[index].layout = tabs[index].layout.swapping(pane, target)
                }
                tabs[index].focusedPane = pane
            } else {
                guard let edge = drop.edge else { return }
                lift(pane)
                guard let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
                tabs[index].layout = tabs[index].layout.inserting(.leaf(pane), at: drop.anchor, edge: edge)
                tabs[index].focusedPane = pane
            }
        }
    }

    func canBreakOut(_ pane: PaneID) -> Bool {
        owns(pane) && (tab(containing: pane)?.layout.leaves.count ?? 0) > 1
    }

    func breakOut(_ pane: PaneID) {
        guard canBreakOut(pane), let origin = tab(containing: pane)?.id else { return }
        lift(pane)
        let tab = ShellTab(layout: .leaf(pane), focusedPane: pane)
        let index = tabs.firstIndex { $0.id == origin } ?? activeIndex
        tabs.insert(tab, at: index + 1)
        activeTabID = tab.id
    }

    func tileBesideActive(_ id: UUID, edge: PaneEdge = .right) {
        drop(.tab(id), on: PaneDrop(anchor: .root, edge: edge))
    }

    func equalizePanes(only split: UUID? = nil) {
        let index = activeIndex
        tabs[index].layout = tabs[index].layout.equalized(only: split)
    }

    private func owns(_ pane: PaneID) -> Bool {
        sessions[pane] != nil || viewers[pane] != nil
    }

    private func removeTab(at index: Int) {
        guard tabs.count > 1 else {
            onEmpty()
            return
        }
        let wasActive = tabs[index].id == activeTabID
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs[max(index - 1, 0)].id
        }
    }

    func closeFocused() {
        if tabs[activeIndex].isSettings {
            closeTab(activeTabID)
            return
        }
        close(focusedPane)
    }

    func focus(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }) else { return }
        if tabs[index].focusedPane != pane { tabs[index].focusedPane = pane }
        if tabs[index].id != activeTabID { activeTabID = tabs[index].id }
        notePaneFocus(pane)
    }

    // views in hidden tabs can still become first responder, which must not pull their tab to the front
    func focusInActiveTab(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }), tabs[index].id == activeTabID else { return }
        if tabs[index].focusedPane != pane { tabs[index].focusedPane = pane }
        notePaneFocus(pane)
    }

    /// Clears key-focus on every other shell immediately, so a pending terminal focus restore cannot steal the editor.
    private func notePaneFocus(_ pane: PaneID) {
        for (id, session) in sessions {
            let focused = id == pane
            if session.isPaneFocused != focused { session.setPaneFocused(focused) }
        }
    }

    func focusNext() {
        moveFocus(by: 1)
    }

    func focusPrevious() {
        moveFocus(by: -1)
    }

    func resize(split id: UUID, to ratio: Double) {
        let index = activeIndex
        tabs[index].layout = tabs[index].layout.resizing(split: id, to: ratio)
    }

    private func moveFocus(by offset: Int) {
        let index = activeIndex
        let order = tabs[index].layout.leaves
        guard order.count > 1, let position = order.firstIndex(of: tabs[index].focusedPane) else { return }
        tabs[index].focusedPane = order[(position + offset + order.count) % order.count]
    }

    private func moveTab(by offset: Int) {
        guard tabs.count > 1 else { return }
        activeTabID = tabs[(activeIndex + offset + tabs.count) % tabs.count].id
    }

    private func makeSession(for pane: PaneID, directory: String? = nil) -> TerminalSession {
        let session = directory.map { TerminalSession(directory: $0) } ?? TerminalSession()
        bind(session, to: pane)
        return session
    }

    private func bind(_ session: TerminalSession, to pane: PaneID) {
        session.onFocus = { [weak self] in self?.focusInActiveTab(pane) }
        session.onExit = { [weak self] in
            guard !WorkspacePersistence.isQuitting else { return }
            self?.removePane(pane)
        }
        session.onPopOut = { [weak self] sub in self?.adopt(sub, from: pane) }
        session.onLayoutChange = { [weak self] in self?.persistLayout() }
        session.onBlockFinished = { [weak self] in self?.persistBlocks() }
        sessions[pane] = session
    }

    /// Opens an already running session, such as a popped-out action shell, as its own tab beside the one it came from.
    func adopt(_ session: TerminalSession, from origin: PaneID? = nil) {
        let pane = PaneID()
        session.adopt()
        bind(session, to: pane)
        let tab = ShellTab(layout: .leaf(pane), focusedPane: pane)
        let source = origin.flatMap { origin in tabs.firstIndex { $0.layout.contains(origin) } } ?? activeIndex
        tabs.insert(tab, at: source + 1)
        activeTabID = tab.id
    }
}
