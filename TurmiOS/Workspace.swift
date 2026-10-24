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
    private(set) var spaceList: [PhoneSpaceInfo]
    private(set) var activeSpaceID: UUID
    private var parked: [UUID: ParkedPhoneSpace] = [:]
    var showsSettings = false
    var showsHostPicker = false
    var showsPairing = false
    var editingHost: SSHHost?

    var selected: (any TerminalTab)? {
        sessions.first { $0.id == selectedID }
    }

    init() {
        let temporary = UUID()
        let id = UUID()
        spaceList = [
            PhoneSpaceInfo(id: temporary, name: SavedSpace.temporaryName, symbol: SavedSpace.temporarySymbol, isTemporary: true),
            PhoneSpaceInfo(id: id, name: "Space", symbol: "terminal"),
        ]
        activeSpaceID = id
        loadPhoneWorkspace()
    }

    var activeSpaceName: String {
        spaceList.first { $0.id == activeSpaceID }?.name ?? "Space"
    }

    func showSpace(_ id: UUID) {
        guard id != activeSpaceID, spaceList.contains(where: { $0.id == id }) else { return }
        parked[activeSpaceID] = ParkedPhoneSpace(sessions: sessions, selectedID: selectedID)
        activeSpaceID = id
        if let restored = parked.removeValue(forKey: id) {
            sessions = restored.sessions
            selectedID = restored.selectedID
        } else {
            sessions = []
            selectedID = nil
        }
        compactColumn = selectedID == nil ? .sidebar : .detail
        persistSessions()
    }

    func createSpace() {
        parked[activeSpaceID] = ParkedPhoneSpace(sessions: sessions, selectedID: selectedID)
        let info = PhoneSpaceInfo(
            id: UUID(), name: nextSpaceName(), symbol: SavedSpace.symbol(at: spaceList.count)
        )
        spaceList.append(info)
        sessions = []
        selectedID = nil
        activeSpaceID = info.id
        compactColumn = .sidebar
        persistSessions()
    }

    func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = spaceList.firstIndex(where: { $0.id == id }), !spaceList[index].isTemporary else { return }
        spaceList[index].name = trimmed
        persistSessions()
    }

    func deleteSpace(_ id: UUID) {
        guard spaceList.count > 1, let target = spaceList.first(where: { $0.id == id }), !target.isTemporary else { return }
        let tabs = id == activeSpaceID ? sessions : (parked[id]?.sessions ?? [])
        for tab in tabs {
            tab.close()
            SessionHub.shared.unassign(tab.id, from: self)
        }
        parked[id] = nil
        spaceList.removeAll { $0.id == id }
        guard activeSpaceID == id else {
            persistSessions()
            return
        }
        activeSpaceID = spaceList[0].id
        if let restored = parked.removeValue(forKey: activeSpaceID) {
            sessions = restored.sessions
            selectedID = restored.selectedID
        } else {
            sessions = []
            selectedID = nil
        }
        compactColumn = selectedID == nil ? .sidebar : .detail
        persistSessions()
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
        if let index = sessions.firstIndex(where: { $0.id == tab.id }) {
            tab.close()
            remove(at: index)
            return
        }
        // A session keeps running after its space is parked. The exit still has to take it out of that space,
        // or the dead tab is saved and comes back the next time the space is opened.
        for key in Array(parked.keys) {
            guard var space = parked[key], let index = space.sessions.firstIndex(where: { $0.id == tab.id }) else { continue }
            tab.close()
            space.sessions.remove(at: index)
            if space.selectedID == tab.id {
                space.selectedID = space.sessions.indices.contains(index) ? space.sessions[index].id : space.sessions.last?.id
            }
            parked[key] = space
            SessionHub.shared.unassign(tab.id, from: self)
            persistSessions()
            return
        }
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
        persistSessions()
    }

    private func remove(at index: Int) {
        let id = sessions[index].id
        sessions.remove(at: index)
        SessionHub.shared.unassign(id, from: self)
        persistSessions()
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


    private var phoneStore: WorkspaceStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return WorkspaceStore(root: appSupport.appendingPathComponent("Turm/PhoneWorkspace"))
    }

    private func nextSpaceName() -> String {
        let used = Set(spaceList.map(\.name))
        if !used.contains("Space") { return "Space" }
        var index = 2
        while used.contains("Space \(index)") { index += 1 }
        return "Space \(index)"
    }

    private func persistSessions() {
        let encoded = spaceList.map { info in
            let tabs = info.isTemporary ? [] : (info.id == activeSpaceID ? sessions : (parked[info.id]?.sessions ?? []))
            return PhoneSpace(
                id: info.id, name: info.name, symbol: info.symbol, sessions: phoneSessions(from: tabs), isTemporary: info.isTemporary
            )
        }
        let active = encoded.first { $0.id == activeSpaceID }?.sessions ?? []
        try? phoneStore.save(PhoneWorkspace(sessions: active, spaces: encoded, activeSpaceID: activeSpaceID))
    }

    private func phoneSessions(from tabs: [any TerminalTab]) -> [PhoneSession] {
        tabs.compactMap { tab in
            if let ssh = tab as? SSHTerminalSession {
                return PhoneSession(id: ssh.id, kind: .ssh(hostID: ssh.host.id))
            }
            if let mac = tab as? MacSession, let macID = mac.shell.macID {
                return PhoneSession(id: mac.id, kind: .mac(sessionID: mac.id, macID: macID))
            }
            return nil
        }
    }

    private func loadPhoneWorkspace() {
        guard let saved = try? phoneStore.loadPhone() else { return }
        let restored = restoredSpaces(from: saved)
        spaceList = restored.list
        activeSpaceID = restored.active
        parked = [:]
        sessions = []
        for info in spaceList {
            let tabs = materialize(restored.sessions[info.id] ?? [])
            if info.id == activeSpaceID {
                sessions = tabs
            } else {
                parked[info.id] = ParkedPhoneSpace(sessions: tabs, selectedID: nil)
            }
        }
        persistSessions()
    }

    private func restoredSpaces(from saved: PhoneWorkspace) -> (list: [PhoneSpaceInfo], active: UUID, sessions: [UUID: [PhoneSession]]) {
        var source = saved.spaces.isEmpty
            ? [PhoneSpace(id: UUID(), name: "Space", symbol: "terminal", sessions: saved.sessions)]
            : saved.spaces
        if !source.contains(where: \.isTemporary) {
            source.insert(
                PhoneSpace(id: UUID(), name: SavedSpace.temporaryName, symbol: SavedSpace.temporarySymbol, sessions: [], isTemporary: true),
                at: 0
            )
        }
        let list = source.map { PhoneSpaceInfo(id: $0.id, name: $0.name, symbol: $0.symbol, isTemporary: $0.isTemporary) }
        let active = saved.activeSpaceID.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
        let sessions = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.isTemporary ? [] : $0.sessions) })
        return (list, active, sessions)
    }

    private func materialize(_ saved: [PhoneSession]) -> [any TerminalTab] {
        let hostStore = SSHHostStore.shared
        return saved.compactMap { session in
            switch session.kind {
            case .ssh(let hostID):
                guard let host = hostStore.hosts.first(where: { $0.id == hostID }) else { return nil }
                let sshSession = SSHTerminalSession(host: host)
                watchExit(of: sshSession)
                SessionHub.shared.assign(sshSession.id, to: self)
                return sshSession
            case .mac:
                return nil
            }
        }
    }
}

struct PhoneSpaceInfo: Identifiable, Equatable {
    let id: UUID
    var name: String
    var symbol: String
    var isTemporary = false
}

private struct ParkedPhoneSpace {
    var sessions: [any TerminalTab]
    var selectedID: UUID?
}
