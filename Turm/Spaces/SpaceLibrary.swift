import AppKit
import Observation
import TurmCore

@MainActor
@Observable
final class WindowHost {
    let id = UUID()
    var spaceID: UUID?
    private(set) var placement: NSRect?
    private var claimed = false

    func claimIfNeeded() {
        guard !claimed else { return }
        claimed = true
        placement = SpaceLibrary.shared.claim(self)
    }
}

struct SpaceActions {
    let library: SpaceLibrary
    let host: WindowHost

    func newSpace() { library.create(in: host) }
    func nextSpace() { library.cycle(host, by: 1) }
    func previousSpace() { library.cycle(host, by: -1) }
    func openCurrentInNewWindow() {
        guard let id = host.spaceID else { return }
        library.openInNewWindow(id)
    }
}

@MainActor
@Observable
final class SpaceLibrary {
    static let shared = SpaceLibrary()

    struct Record: Identifiable {
        let id: UUID
        var name: String
        var symbol: String
        var workspace: Workspace?
        var snapshot: SavedWindow?
        var isTemporary = false
    }

    private(set) var records: [Record] = []
    private var hosts: [UUID: WindowHost] = [:]
    private var loaded = false
    private var didClaimLaunch = false
    private var launchSpaceID: UUID?

    func record(_ id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    func workspace(for host: WindowHost) -> Workspace {
        host.claimIfNeeded()
        if let id = host.spaceID {
            materialize(id)
            if let workspace = record(id)?.workspace { return workspace }
        }
        let created = makeLive(name: nextName(), symbol: SavedSpace.symbol(at: records.count))
        bind(host, to: created.id, frame: nil)
        guard let workspace = created.workspace else {
            preconditionFailure("A new space always has a live workspace")
        }
        return workspace
    }

    @discardableResult
    func claim(_ host: WindowHost) -> NSRect? {
        if let pending = WindowTransfer.shared.take() {
            if let shell = pending.shell {
                didClaimLaunch = true
                ensureTemporary()
                let space = makeLive(transfer: shell, name: shell.title ?? nextName(), symbol: SavedSpace.symbol(at: records.count))
                return bind(host, to: space.id, frame: pending.frame)
            }
            if let spaceID = pending.spaceID {
                ensureLoaded()
                if records.contains(where: { $0.id == spaceID }) {
                    materialize(spaceID)
                    return bind(host, to: spaceID, frame: nil)
                }
            }
        }
        ensureLoaded()
        if !didClaimLaunch, let key = launchRecord() {
            didClaimLaunch = true
            materialize(key.id)
            return bind(host, to: key.id, frame: key.snapshot?.frame.map(Self.rect))
        }
        didClaimLaunch = true
        ensureTemporary()
        let space = makeLive(name: nextName(), symbol: SavedSpace.symbol(at: records.count))
        return bind(host, to: space.id, frame: nil)
    }

    func activate(_ id: UUID, in host: WindowHost) {
        guard records.contains(where: { $0.id == id }) else { return }
        materialize(id)
        // Claim before moving anyone else, so this window's previous space is free to receive them.
        host.spaceID = id
        hosts[host.id] = host
        vacate(id, keeping: host)
        if let workspace = record(id)?.workspace, let window = NSApp.keyWindow {
            ContextMenuService.shared.register(workspace, in: window)
        }
    }

    func create(in host: WindowHost, name: String? = nil, symbol: String? = nil) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? nextName() : trimmed
        let icon = symbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = makeLive(name: resolved, symbol: (icon?.isEmpty == false ? icon! : nil) ?? SavedSpace.symbol(at: records.count))
        activate(space.id, in: host)
    }

    func cycle(_ host: WindowHost, by delta: Int) {
        guard !records.isEmpty, let current = host.spaceID, let index = records.firstIndex(where: { $0.id == current }) else { return }
        let next = (index + delta + records.count) % records.count
        activate(records[next].id, in: host)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = records.firstIndex(where: { $0.id == id }), !records[index].isTemporary else { return }
        records[index].name = trimmed
        if let workspace = records[index].workspace {
            workspace.spaceName = trimmed
            WorkspacePersistence.save(workspace)
        } else {
            WorkspacePersistence.renameSpace(id, to: trimmed)
        }
    }

    func setSymbol(_ id: UUID, to symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = records.firstIndex(where: { $0.id == id }), !records[index].isTemporary else { return }
        records[index].symbol = trimmed
        if let workspace = records[index].workspace {
            workspace.spaceSymbol = trimmed
            WorkspacePersistence.save(workspace)
        } else {
            WorkspacePersistence.setSpaceSymbol(id, to: trimmed)
        }
    }

    func delete(_ id: UUID, from host: WindowHost) {
        guard records.count > 1, let index = records.firstIndex(where: { $0.id == id }), !records[index].isTemporary else { return }
        if let workspace = records[index].workspace {
            let busy = workspace.shellsRequiringConfirmationCount
            if busy > 0, !CloseCoordinator.shared.confirm(.window(shellCount: busy)) { return }
            workspace.terminateAll()
        }
        discard(at: index, from: host)
    }

    /// The last shell in a space is already gone. A saved space closes and the window moves on.
    /// Tmp stays, with a fresh shell: it is the scratch space and is not something the window can leave behind.
    func dropEmpty(_ id: UUID, from host: WindowHost) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if records[index].isTemporary {
            reseedTemporary(at: index)
            return
        }
        guard records.count > 1 else { return }
        records[index].workspace?.terminateAll()
        discard(at: index, from: host)
    }

    private func discard(at index: Int, from host: WindowHost) {
        let id = records[index].id
        records.remove(at: index)
        WorkspacePersistence.removeSpace(id)
        let fallback = records[0].id
        materialize(fallback)
        for bound in hosts.values where bound.spaceID == id || bound.spaceID == nil {
            bound.spaceID = fallback
        }
        if host.spaceID == id || host.spaceID == nil { host.spaceID = fallback }
    }

    func openInNewWindow(_ id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        materialize(id)
        vacate(id, keeping: nil)
        WindowTransfer.shared.enqueue(space: id)
        NewWindowAction.open()
    }

    /// A space's shells, and a full-screen program's view, can live in one window only.
    /// Any other window that was showing `id` moves to a space nobody else is showing.
    private func vacate(_ id: UUID, keeping host: WindowHost?) {
        let displaced = hosts.values.filter { $0.id != host?.id && $0.spaceID == id }
        var taken = Set(hosts.values.compactMap(\.spaceID))
        taken.insert(id)
        for other in displaced {
            let next = replacement(excluding: taken)
            taken.insert(next)
            other.spaceID = next
        }
    }

    private func replacement(excluding taken: Set<UUID>) -> UUID {
        if let existing = records.first(where: { !$0.isTemporary && !taken.contains($0.id) })?.id {
            materialize(existing)
            return existing
        }
        if let existing = records.first(where: { !taken.contains($0.id) })?.id {
            materialize(existing)
            return existing
        }
        return makeLive(name: nextName(), symbol: SavedSpace.symbol(at: records.count)).id
    }

    func shellsRequiringConfirmation() -> Int {
        records.reduce(0) { count, record in
            count + (record.workspace?.shellsRequiringConfirmationCount ?? 0)
        }
    }

    /// Closing a window does not delete its space. It does decide which space comes back on the next launch:
    /// the last window to close wins, and closing one of several windows leaves the key mark on a window that is still open.
    func noteWindowClosing(_ host: WindowHost, frame: NSRect, isLast: Bool) {
        defer { hosts[host.id] = nil }
        guard let id = host.spaceID else { return }
        materialize(id)
        guard let closing = record(id)?.workspace else { return }
        let wasKey = closing.savedIsKey
        if isLast {
            for record in records { record.workspace?.releaseKey() }
            closing.noteFrame(frame, isKey: true)
            return
        }
        closing.noteFrame(frame, isKey: false)
        let keyRemains = records.contains { $0.id != id && ($0.workspace?.savedIsKey ?? false) }
        guard wasKey || !keyRemains else { return }
        guard let successor = hosts.values.first(where: { $0.id != host.id && $0.spaceID != nil })?.spaceID else { return }
        materialize(successor)
        guard let workspace = record(successor)?.workspace else { return }
        for record in records { record.workspace?.releaseKey() }
        workspace.claimKey()
    }

    func noteFrontWindow() {
        guard let window = NSApp.keyWindow else { return }
        let front = ContextMenuService.shared.workspace(in: window)
        for record in records {
            guard let workspace = record.workspace else { continue }
            if workspace === front {
                workspace.noteFrame(window.frame, isKey: true)
            } else {
                workspace.releaseKey()
            }
        }
    }

    func saveAll() {
        for index in records.indices {
            guard let workspace = records[index].workspace else { continue }
            workspace.spaceName = records[index].name
            workspace.spaceSymbol = records[index].symbol
            WorkspacePersistence.save(workspace, force: true)
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard var document = WorkspacePersistence.consumeLaunchDocument() else { return }
        let kept = document.discardingTemporarySpaces()
        if kept != document {
            document = kept
            try? WorkspacePersistence.store().save(document)
        }
        if document.spaces.isEmpty, !document.windows.isEmpty {
            var migrated = document
            migrated.spaces = document.spaceCatalog
            try? WorkspacePersistence.store().save(migrated)
            document = migrated
        }
        launchSpaceID = document.space(forKey: document.keyWindowID)?.id
        records = document.spaceCatalog.map {
            Record(
                id: $0.id, name: $0.name, symbol: $0.symbol, workspace: nil, snapshot: $0.session,
                isTemporary: $0.isTemporary
            )
        }
        ensureTemporary()
    }

    private func launchRecord() -> Record? {
        if let launchSpaceID, let match = records.first(where: { $0.id == launchSpaceID }), !match.isTemporary {
            return match
        }
        return records.first { !$0.isTemporary } ?? records.first
    }

    private func materialize(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].workspace == nil else { return }
        let record = records[index]
        let workspace: Workspace
        if !record.isTemporary, let snapshot = record.snapshot, !snapshot.tabs.isEmpty {
            workspace = Workspace(restoring: snapshot)
        } else {
            workspace = Workspace()
        }
        workspace.spaceID = record.id
        workspace.spaceName = record.name
        workspace.spaceSymbol = record.symbol
        workspace.isTemporarySpace = record.isTemporary
        records[index].workspace = workspace
    }

    @discardableResult
    private func makeLive(name: String, symbol: String) -> Record {
        makeLive(transfer: nil, name: name, symbol: symbol, temporary: false)
    }

    private func reseedTemporary(at index: Int) {
        let existing = records[index]
        existing.workspace?.terminateAll()
        let workspace = Workspace()
        workspace.spaceID = existing.id
        workspace.spaceName = existing.name
        workspace.spaceSymbol = existing.symbol
        workspace.isTemporarySpace = true
        records[index].workspace = workspace
    }

    private func ensureTemporary() {
        guard !records.contains(where: \.isTemporary) else { return }
        let created = makeLive(transfer: nil, name: SavedSpace.temporaryName, symbol: SavedSpace.temporarySymbol, temporary: true)
        guard let index = records.firstIndex(where: { $0.id == created.id }), index != 0 else { return }
        records.insert(records.remove(at: index), at: 0)
    }

    @discardableResult
    private func makeLive(transfer: ShellTransfer?, name: String, symbol: String, temporary: Bool = false) -> Record {
        let workspace = transfer.map { Workspace(transfer: $0) } ?? Workspace()
        let id = workspace.windowID
        workspace.spaceID = id
        workspace.spaceName = name
        workspace.spaceSymbol = symbol
        workspace.isTemporarySpace = temporary
        let record = Record(id: id, name: name, symbol: symbol, workspace: workspace, snapshot: nil, isTemporary: temporary)
        records.append(record)
        if !temporary { WorkspacePersistence.save(workspace) }
        return record
    }

    @discardableResult
    private func bind(_ host: WindowHost, to spaceID: UUID, frame: NSRect?) -> NSRect? {
        hosts[host.id] = host
        host.spaceID = spaceID
        return frame
    }

    private func nextName() -> String {
        let used = Set(records.map(\.name))
        if !used.contains("Space") { return "Space" }
        var index = 2
        while used.contains("Space \(index)") { index += 1 }
        return "Space \(index)"
    }

    private static func rect(_ frame: SavedFrame) -> NSRect {
        NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
