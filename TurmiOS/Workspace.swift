import Observation
import SwiftUI
import TurmCore

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
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            close(session)
        }
        sessions.append(session)
        selectedID = session.id
        compactColumn = .detail
        session.connect()
    }

    func open(_ tab: any TerminalTab) {
        if !sessions.contains(where: { $0.id == tab.id }) { sessions.append(tab) }
        select(tab)
    }

    func select(_ tab: any TerminalTab) {
        selectedID = tab.id
        compactColumn = .detail
    }

    func close(_ tab: any TerminalTab) {
        guard let index = sessions.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close()
        sessions.remove(at: index)
        guard selectedID == tab.id else { return }
        selectedID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        if selectedID == nil { compactColumn = .sidebar }
    }

    func closeSelected() {
        if let selected { close(selected) }
    }
}
