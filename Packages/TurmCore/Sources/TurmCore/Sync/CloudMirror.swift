import Foundation

// the shipping store is iCloud Keychain, which is end-to-end encrypted
protocol SyncRecordStore: AnyObject {
    func accounts(in collection: String) -> [String]
    func data(in collection: String, account: String) -> Data?
    @discardableResult func set(_ data: Data, in collection: String, account: String) -> Bool
    func remove(in collection: String, account: String)
    func removeAll(in collection: String)
}

enum SyncCollection {
    static let host = "host"
    static let shortcut = "shortcut"
    static let key = "key"
    static let meta = "meta"
    static let records = [host, shortcut, key]
    static let resetAccount = "reset"
}

enum MirrorEvent: Equatable {
    case synced(Date)
    case reset
}

struct SyncTombstone: Codable, Equatable {
    var deleted: Date
}

final class CloudMirror {
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    private struct Plan<Record> {
        var incoming: [Record] = []
        var removed: [UUID] = []
        var push: [Record] = []
    }

    private let store: SyncRecordStore
    private let hosts: SSHHostStore
    private let shortcuts: ShortcutStore
    private let identities: SSHIdentityStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var isRunning = false
    var onEvent: ((MirrorEvent) -> Void)?

    init(
        store: SyncRecordStore, hosts: SSHHostStore, shortcuts: ShortcutStore, identities: SSHIdentityStore,
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.hosts = hosts
        self.shortcuts = shortcuts
        self.identities = identities
        self.defaults = defaults
        self.now = now
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hosts.onChange = { [weak self] in self?.hostChanged($0) }
        shortcuts.onChange = { [weak self] in self?.shortcutChanged($0) }
        identities.onChange = { [weak self] in self?.identityChanged($0) }
        pull()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        hosts.onChange = nil
        shortcuts.onChange = nil
        identities.onChange = nil
    }

    func pull() {
        guard isRunning else { return }
        if resetPending() {
            onEvent?(.reset)
            return
        }
        pruneTombstones()
        let localShortcuts = shortcuts.items.filter { !$0.isProject }
        let hostPlan = plan(SyncCollection.host, local: hosts.hosts, id: \.id) { $0.modified ?? .distantPast }
        let shortcutPlan = plan(SyncCollection.shortcut, local: localShortcuts, id: \.id) { $0.modified ?? .distantPast }
        let keyPlan = plan(SyncCollection.key, local: identities.identities, id: \.id) { $0.created }
        hosts.applyRemote(hostPlan.incoming, removing: hostPlan.removed)
        shortcuts.applyRemote(shortcutPlan.incoming.filter { !$0.isProject }, removing: shortcutPlan.removed)
        identities.applyRemote(keyPlan.incoming, removing: keyPlan.removed)
        for host in hostPlan.push { put(host, SyncCollection.host, host.id) }
        for shortcut in shortcutPlan.push { put(shortcut, SyncCollection.shortcut, shortcut.id) }
        for identity in keyPlan.push { put(identity, SyncCollection.key, identity.id) }
        finish()
    }

    static func resetCloud(_ store: SyncRecordStore, at date: Date) {
        for collection in SyncCollection.records { store.removeAll(in: collection) }
        if let data = try? JSONEncoder().encode(date) {
            store.set(data, in: SyncCollection.meta, account: SyncCollection.resetAccount)
        }
    }

    private func resetPending() -> Bool {
        guard let data = store.data(in: SyncCollection.meta, account: SyncCollection.resetAccount),
              let date = try? JSONDecoder().decode(Date.self, from: data)
        else { return false }
        return date.timeIntervalSince1970 > defaults.double(forKey: SyncPreference.enabledAtKey)
    }

    private func plan<Record: Codable>(
        _ collection: String, local: [Record], id: KeyPath<Record, UUID>, stamp: (Record) -> Date
    ) -> Plan<Record> {
        var plan = Plan<Record>()
        var seen = Set<UUID>()
        let decoder = JSONDecoder()
        for account in store.accounts(in: collection) {
            guard let uuid = UUID(uuidString: account), let data = store.data(in: collection, account: account) else { continue }
            seen.insert(uuid)
            let mine = local.first { $0[keyPath: id] == uuid }
            if let tombstone = try? decoder.decode(SyncTombstone.self, from: data) {
                guard let mine else { continue }
                if stamp(mine) <= tombstone.deleted { plan.removed.append(uuid) } else { plan.push.append(mine) }
            } else if let remote = try? decoder.decode(Record.self, from: data) {
                guard let mine else {
                    plan.incoming.append(remote)
                    continue
                }
                let theirs = stamp(remote)
                let ours = stamp(mine)
                if theirs > ours { plan.incoming.append(remote) } else if ours > theirs { plan.push.append(mine) }
            }
        }
        plan.push += local.filter { !seen.contains($0[keyPath: id]) }
        return plan
    }

    private func hostChanged(_ change: RecordChange<SSHHost>) {
        switch change {
        case .saved(let host): put(host, SyncCollection.host, host.id)
        case .removed(let id): bury(SyncCollection.host, id)
        }
        finish()
    }

    private func shortcutChanged(_ change: RecordChange<Shortcut>) {
        switch change {
        case .saved(let shortcut):
            guard !shortcut.isProject else { return }
            put(shortcut, SyncCollection.shortcut, shortcut.id)
        case .removed(let id): bury(SyncCollection.shortcut, id)
        }
        finish()
    }

    private func identityChanged(_ change: RecordChange<SSHIdentity>) {
        switch change {
        case .saved(let identity): put(identity, SyncCollection.key, identity.id)
        case .removed(let id): bury(SyncCollection.key, id)
        }
        finish()
    }

    private func put(_ record: some Encodable, _ collection: String, _ id: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        store.set(data, in: collection, account: id.uuidString)
    }

    private func bury(_ collection: String, _ id: UUID) {
        put(SyncTombstone(deleted: now()), collection, id)
    }

    private func finish() {
        let date = now()
        defaults.set(date.timeIntervalSince1970, forKey: SyncPreference.lastSyncKey)
        onEvent?(.synced(date))
    }

    private func pruneTombstones() {
        let cutoff = now().addingTimeInterval(-Self.tombstoneLifetime)
        for collection in SyncCollection.records {
            for account in store.accounts(in: collection) {
                guard let data = store.data(in: collection, account: account),
                      let tombstone = try? JSONDecoder().decode(SyncTombstone.self, from: data), tombstone.deleted < cutoff
                else { continue }
                store.remove(in: collection, account: account)
            }
        }
    }
}
