import Observation
import SwiftUI
import TurmCore
import UIKit

enum TabIndicator {
    case live
    case busy
    case down

    var color: Color {
        switch self {
        case .live: Chrome.success
        case .busy: Chrome.warning
        case .down: Chrome.failure
        }
    }
}

protocol TerminalTab: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var subtitle: String { get }
    var indicator: TabIndicator { get }
    var program: RunningProgram? { get }
    var programActivity: CompanionActivity { get }
    func close()
}

enum WorkspaceColumn {
    case sidebar
    case detail
}

@Observable
final class Workspace {
    private(set) var sessions: [any TerminalTab] = []
    var selectedID: UUID?
    var compactColumn = WorkspaceColumn.sidebar
    var sidebarHidden = false
    var showsSettings = false
    var showsHostPicker = false
    var showsPairing = false
    var editingHost: SSHHost?

    var selected: (any TerminalTab)? {
        sessions.first { $0.id == selectedID }
    }

    func open(_ host: SSHHost) {
        let session = SSHTerminalSession(host: host)
        watchExit(of: session)
        append(session)
        selectedID = session.id
        compactColumn = .detail
        session.connect()
    }

    func open(_ tab: any TerminalTab) {
        let tab = SessionHub.shared.transfer(tab, to: self)
        if let ssh = tab as? SSHTerminalSession { watchExit(of: ssh) }
        if !sessions.contains(where: { $0.id == tab.id }) { append(tab) }
        select(tab)
    }

    func select(_ tab: any TerminalTab) {
        selectedID = tab.id
        compactColumn = .detail
    }

    func close(_ tab: any TerminalTab) {
        guard let index = sessions.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close()
        remove(at: index)
    }

    func release(_ id: UUID) -> (any TerminalTab)? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = sessions[index]
        detachViews(of: tab)
        remove(at: index)
        return tab
    }

    func closeSelected() {
        if let selected { close(selected) }
    }

    func closeAll() {
        for tab in sessions { tab.close() }
        for index in sessions.indices.reversed() { remove(at: index) }
    }

    private func append(_ tab: any TerminalTab) {
        sessions.append(tab)
        SessionHub.shared.assign(tab.id, to: self)
    }

    private func remove(at index: Int) {
        let id = sessions[index].id
        sessions.remove(at: index)
        SessionHub.shared.unassign(id, from: self)
        guard selectedID == id else { return }
        selectedID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        if selectedID == nil { compactColumn = .sidebar }
    }

    private func watchExit(of session: SSHTerminalSession) {
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            close(session)
        }
    }

    // a terminal view can live in one window only, so it must leave this one before another adopts it
    private func detachViews(of tab: any TerminalTab) {
        var views: [UIView] = []
        if let ssh = tab as? SSHTerminalSession { views.append(ssh.surface.view) }
        if let blocks = tab as? any BlockSession, let surface = blocks.fullScreen { views.append(surface.view) }
        for view in views {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
        }
    }
}
