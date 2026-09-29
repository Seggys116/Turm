import Foundation
import Observation

nonisolated struct ShellTab: Identifiable, Equatable, Sendable {
    let id = UUID()
    var layout: PaneNode
    var focusedPane: PaneID
}

@Observable
final class Workspace {
    private(set) var tabs: [ShellTab]
    private(set) var activeTabID: UUID
    private var sessions: [PaneID: TerminalSession] = [:]
    private let closeCoordinator: CloseCoordinator

    var onEmpty: () -> Void = {}

    init(closeCoordinator: CloseCoordinator = .shared) {
        self.closeCoordinator = closeCoordinator
        let first = PaneID()
        let tab = ShellTab(layout: .leaf(first), focusedPane: first)
        tabs = [tab]
        activeTabID = tab.id
        sessions[first] = makeSession(for: first)
        closeCoordinator.register(self)
    }

    deinit {
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
        sessions[focusedPane]?.title ?? "Turm"
    }

    var focusedSession: TerminalSession? {
        sessions[focusedPane]
    }

    var openShellCount: Int {
        sessions.values.filter(\.isOpen).count
    }

    var shellsRequiringConfirmationCount: Int {
        sessions.values.filter { $0.isOpen && $0.hasSubmittedCommand }.count
    }

    func shouldCloseWindow() -> Bool {
        let count = shellsRequiringConfirmationCount
        return count == 0 || closeCoordinator.confirm(.window(shellCount: count))
    }

    func terminateAll() {
        let closing = Array(sessions.values)
        sessions.removeAll()
        closing.forEach { $0.terminate() }
    }

    func split(_ axis: SplitAxis) {
        let newPane = PaneID()
        sessions[newPane] = makeSession(for: newPane)
        let index = activeIndex
        tabs[index].layout = tabs[index].layout.splitting(tabs[index].focusedPane, axis: axis, inserting: newPane)
        tabs[index].focusedPane = newPane
    }

    func newShell() {
        let pane = PaneID()
        sessions[pane] = makeSession(for: pane, directory: focusedSession?.directory)
        let tab = ShellTab(layout: .leaf(pane), focusedPane: pane)
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
        let panes = tab.layout.leaves
        let needsConfirmation = panes.contains { pane in
            guard let session = sessions[pane] else { return false }
            return session.hasSubmittedCommand && session.hasRunningJobs
        }
        if needsConfirmation, !closeCoordinator.confirm(.shell) { return }
        panes.forEach(removePane)
    }

    func close(_ pane: PaneID) {
        guard let session = sessions[pane] else { return }
        if session.hasSubmittedCommand, session.hasRunningJobs,
           !closeCoordinator.confirm(.shell) { return }
        removePane(pane)
    }

    private func removePane(_ pane: PaneID) {
        guard sessions[pane] != nil, let index = tabs.firstIndex(where: { $0.layout.contains(pane) }) else { return }
        let order = tabs[index].layout.leaves
        sessions.removeValue(forKey: pane)?.terminate()

        guard let remaining = tabs[index].layout.removing(pane) else {
            removeTab(at: index)
            return
        }
        tabs[index].layout = remaining
        if tabs[index].focusedPane == pane, let position = order.firstIndex(of: pane) {
            tabs[index].focusedPane = remaining.leaves[max(position - 1, 0)]
        }
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
        close(focusedPane)
    }

    func focus(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }) else { return }
        if tabs[index].focusedPane != pane { tabs[index].focusedPane = pane }
        if tabs[index].id != activeTabID { activeTabID = tabs[index].id }
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
        session.onFocus = { [weak self] in self?.focus(pane) }
        session.onExit = { [weak self] in self?.removePane(pane) }
        return session
    }
}
