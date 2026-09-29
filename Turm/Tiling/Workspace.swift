import Foundation
import Observation

@Observable
final class Workspace {
    private(set) var layout: PaneNode
    private(set) var focusedPane: PaneID
    private var sessions: [PaneID: TerminalSession] = [:]
    private let closeCoordinator: CloseCoordinator

    var onEmpty: () -> Void = {}

    init(closeCoordinator: CloseCoordinator = .shared) {
        self.closeCoordinator = closeCoordinator
        let first = PaneID()
        layout = .leaf(first)
        focusedPane = first
        sessions[first] = makeSession(for: first)
        closeCoordinator.register(self)
    }

    deinit {
        sessions.values.forEach { $0.terminate() }
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
        layout = layout.splitting(focusedPane, axis: axis, inserting: newPane)
        focusedPane = newPane
    }

    func close(_ pane: PaneID) {
        guard let session = sessions[pane] else { return }
        if session.hasSubmittedCommand, session.hasRunningJobs,
           !closeCoordinator.confirm(.shell) { return }
        removePane(pane)
    }

    private func removePane(_ pane: PaneID) {
        guard sessions[pane] != nil else { return }
        let order = layout.leaves
        sessions.removeValue(forKey: pane)?.terminate()

        guard let remaining = layout.removing(pane) else {
            onEmpty()
            return
        }
        layout = remaining
        if focusedPane == pane, let index = order.firstIndex(of: pane) {
            focusedPane = remaining.leaves[max(index - 1, 0)]
        }
    }

    func closeFocused() {
        close(focusedPane)
    }

    func focus(_ pane: PaneID) {
        guard layout.contains(pane), focusedPane != pane else { return }
        focusedPane = pane
    }

    func focusNext() {
        moveFocus(by: 1)
    }

    func focusPrevious() {
        moveFocus(by: -1)
    }

    func resize(split id: UUID, to ratio: Double) {
        layout = layout.resizing(split: id, to: ratio)
    }

    private func moveFocus(by offset: Int) {
        let order = layout.leaves
        guard order.count > 1, let index = order.firstIndex(of: focusedPane) else { return }
        focusedPane = order[(index + offset + order.count) % order.count]
    }

    private func makeSession(for pane: PaneID) -> TerminalSession {
        let session = TerminalSession()
        session.onFocus = { [weak self] in self?.focus(pane) }
        session.onExit = { [weak self] in self?.removePane(pane) }
        return session
    }
}
