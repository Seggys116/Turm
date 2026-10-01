import Foundation
import Testing
@testable import TurmCore

final class FakeRecordStore: SyncRecordStore {
    var records: [String: [String: Data]] = [:]

    func accounts(in collection: String) -> [String] { Array(records[collection, default: [:]].keys) }

    func data(in collection: String, account: String) -> Data? { records[collection]?[account] }

    @discardableResult
    func set(_ data: Data, in collection: String, account: String) -> Bool {
        records[collection, default: [:]][account] = data
        return true
    }

    func remove(in collection: String, account: String) { records[collection]?[account] = nil }

    func removeAll(in collection: String) { records[collection] = [:] }
}

private final class EventLog {
    var events: [MirrorEvent] = []
    var resets: Int { events.filter { $0 == .reset }.count }
}

private struct Device {
    let hosts: SSHHostStore
    let shortcuts: ShortcutStore
    let identities: SSHIdentityStore
    let mirror: CloudMirror
    let defaults: UserDefaults
    let log = EventLog()
    private let suite: String

    init(store: FakeRecordStore, enabledAt: Date = Date(timeIntervalSince1970: 1_000), now: @escaping () -> Date = Date.init) throws {
        suite = "turm.sync.tests." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(enabledAt.timeIntervalSince1970, forKey: SyncPreference.enabledAtKey)
        hosts = SSHHostStore(defaults: defaults)
        shortcuts = ShortcutStore(defaults: defaults)
        identities = SSHIdentityStore(defaults: defaults, backing: MemoryBacking())
        mirror = CloudMirror(store: store, hosts: hosts, shortcuts: shortcuts, identities: identities, defaults: defaults, now: now)
        let log = log
        mirror.onEvent = { log.events.append($0) }
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

private func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
    try JSONDecoder().decode(type, from: try #require(data))
}

private func encode(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
}

struct SyncMirrorTests {
    @Test func localSaveIsPushedAsOneRecord() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.mirror.start()
        #expect(device.hosts.save(SSHHost(key: "prod", hostname: "example.com")))
        let saved = try #require(device.hosts.hosts.first)
        let remote = try decode(SSHHost.self, store.data(in: SyncCollection.host, account: saved.id.uuidString))
        #expect(remote == saved)
        #expect(saved.modified != nil)
    }

    @Test func existingLocalRecordsAreUploadedOnFirstPull() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        device.shortcuts.save(Shortcut(kind: .command, key: "ll", name: "", value: "ls -la"))
        device.mirror.start()
        #expect(store.accounts(in: SyncCollection.host).count == 1)
        #expect(store.accounts(in: SyncCollection.shortcut).count == 1)
    }

    @Test func newerRemoteRecordReplacesLocalWithoutWritingBack() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.hosts.save(SSHHost(key: "prod", hostname: "old.example.com"))
        var local = try #require(device.hosts.hosts.first)
        local.hostname = "new.example.com"
        local.modified = Date().addingTimeInterval(600)
        store.records[SyncCollection.host] = [local.id.uuidString: try encode(local)]
        var pushes = 0
        device.mirror.onEvent = { _ in pushes += 1 }
        device.mirror.start()
        #expect(device.hosts.hosts.first?.hostname == "new.example.com")
        let remote = try decode(SSHHost.self, store.data(in: SyncCollection.host, account: local.id.uuidString))
        #expect(remote == local)
        #expect(pushes == 1)
    }

    @Test func olderRemoteRecordLosesToLocal() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.hosts.save(SSHHost(key: "prod", hostname: "mine.example.com"))
        var stale = try #require(device.hosts.hosts.first)
        stale.hostname = "stale.example.com"
        stale.modified = Date(timeIntervalSince1970: 5_000)
        store.records[SyncCollection.host] = [stale.id.uuidString: try encode(stale)]
        device.mirror.start()
        #expect(device.hosts.hosts.first?.hostname == "mine.example.com")
        let remote = try decode(SSHHost.self, store.data(in: SyncCollection.host, account: stale.id.uuidString))
        #expect(remote.hostname == "mine.example.com")
    }

    @Test func recordsFromAnotherDeviceAppear() throws {
        let store = FakeRecordStore()
        let first = try Device(store: store)
        let second = try Device(store: store)
        defer {
            first.cleanup()
            second.cleanup()
        }
        first.mirror.start()
        second.mirror.start()
        first.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        first.shortcuts.save(Shortcut(kind: .directory, key: "proj", name: "Project", value: "/tmp/project"))
        second.mirror.pull()
        #expect(second.hosts.hosts.map(\.key) == ["prod"])
        #expect(second.shortcuts.items.map(\.key) == ["proj"])
    }

    @Test func deletionPropagatesAndIsNotResurrected() throws {
        let store = FakeRecordStore()
        let first = try Device(store: store)
        let second = try Device(store: store)
        defer {
            first.cleanup()
            second.cleanup()
        }
        first.mirror.start()
        second.mirror.start()
        first.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        second.mirror.pull()
        let id = try #require(first.hosts.hosts.first?.id)
        first.hosts.remove(id)
        _ = try decode(SyncTombstone.self, store.data(in: SyncCollection.host, account: id.uuidString))
        second.mirror.pull()
        #expect(second.hosts.hosts.isEmpty)
        first.mirror.pull()
        second.mirror.pull()
        #expect(first.hosts.hosts.isEmpty)
        #expect(second.hosts.hosts.isEmpty)
    }

    @Test func recordSavedAfterDeletionWinsOverTombstone() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        let host = try #require(device.hosts.hosts.first)
        let buried = SyncTombstone(deleted: Date().addingTimeInterval(-3_600))
        store.records[SyncCollection.host] = [host.id.uuidString: try encode(buried)]
        device.mirror.start()
        #expect(device.hosts.hosts.count == 1)
        _ = try decode(SSHHost.self, store.data(in: SyncCollection.host, account: host.id.uuidString))
    }

    @Test func oldTombstonesArePruned() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        let ancient = SyncTombstone(deleted: Date().addingTimeInterval(-CloudMirror.tombstoneLifetime - 10))
        let recent = SyncTombstone(deleted: Date())
        let oldID = UUID()
        let newID = UUID()
        store.records[SyncCollection.shortcut] = [oldID.uuidString: try encode(ancient), newID.uuidString: try encode(recent)]
        device.mirror.start()
        #expect(store.accounts(in: SyncCollection.shortcut) == [newID.uuidString])
    }

    @Test func projectShortcutsAreNotSynced() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.mirror.start()
        device.shortcuts.save(Shortcut(kind: .command, key: "build", name: "", value: "make", projectRoot: "/tmp/p"))
        #expect(store.accounts(in: SyncCollection.shortcut).isEmpty)
    }

    @Test func keyMetadataSyncsAndRemovalLeavesTombstone() throws {
        let store = FakeRecordStore()
        let first = try Device(store: store)
        let second = try Device(store: store)
        defer {
            first.cleanup()
            second.cleanup()
        }
        first.mirror.start()
        second.mirror.start()
        let identity = try first.identities.importKey(name: "k", privateKey: KeyFixtures.ed25519(), passphrase: nil)
        second.mirror.pull()
        #expect(second.identities.identity(identity.id) == identity)
        #expect(second.identities.privateKey(for: identity.id) == nil)
        first.identities.remove(identity.id)
        second.mirror.pull()
        #expect(second.identities.identities.isEmpty)
    }

    @Test func stoppedMirrorIgnoresLocalChanges() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.mirror.start()
        device.mirror.stop()
        device.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        #expect(store.accounts(in: SyncCollection.host).isEmpty)
        device.mirror.pull()
        #expect(store.accounts(in: SyncCollection.host).isEmpty)
    }
}

struct SyncResetTests {
    @Test func resetWrittenAfterEnablingStopsThisDevice() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store, enabledAt: Date(timeIntervalSince1970: 1_000))
        defer { device.cleanup() }
        store.records[SyncCollection.host] = [UUID().uuidString: try encode(SSHHost(key: "x", hostname: "x.com", modified: Date()))]
        store.set(try encode(Date(timeIntervalSince1970: 2_000)), in: SyncCollection.meta, account: SyncCollection.resetAccount)
        device.mirror.start()
        #expect(device.log.resets == 1)
        #expect(device.hosts.hosts.isEmpty)
    }

    @Test func resetFromBeforeEnablingIsIgnored() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store, enabledAt: Date(timeIntervalSince1970: 3_000))
        defer { device.cleanup() }
        store.set(try encode(Date(timeIntervalSince1970: 2_000)), in: SyncCollection.meta, account: SyncCollection.resetAccount)
        device.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        device.mirror.start()
        #expect(device.log.resets == 0)
        #expect(store.accounts(in: SyncCollection.host).count == 1)
    }

    @Test func resetCloudClearsRecordsAndLeavesMarker() throws {
        let store = FakeRecordStore()
        let device = try Device(store: store)
        defer { device.cleanup() }
        device.mirror.start()
        device.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        device.shortcuts.save(Shortcut(kind: .command, key: "ll", name: "", value: "ls"))
        let date = Date(timeIntervalSince1970: 9_000)
        CloudMirror.resetCloud(store, at: date)
        for collection in SyncCollection.records { #expect(store.accounts(in: collection).isEmpty) }
        let marker = try decode(Date.self, store.data(in: SyncCollection.meta, account: SyncCollection.resetAccount))
        #expect(marker == date)
    }

    @Test func otherDeviceStopsAfterReset() throws {
        let store = FakeRecordStore()
        let first = try Device(store: store, enabledAt: Date(timeIntervalSince1970: 1_000))
        let second = try Device(store: store, enabledAt: Date(timeIntervalSince1970: 1_000))
        defer {
            first.cleanup()
            second.cleanup()
        }
        first.mirror.start()
        second.mirror.start()
        first.hosts.save(SSHHost(key: "prod", hostname: "example.com"))
        second.mirror.pull()
        CloudMirror.resetCloud(store, at: Date())
        second.mirror.pull()
        #expect(second.log.resets == 1)
        #expect(second.hosts.hosts.count == 1)
    }
}

struct SyncStoreHookTests {
    @Test func shortcutDecodesWithoutModified() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kind":"command","key":"ll","name":"","value":"ls -la"}"#
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: Data(json.utf8))
        #expect(shortcut.id == id)
        #expect(shortcut.modified == nil)
    }

    @Test func shortcutStoreStampsModifiedAndReportsChanges() throws {
        let suite = "turm.sync.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        var saved: [Shortcut] = []
        var removed: [UUID] = []
        store.onChange = {
            switch $0 {
            case .saved(let shortcut): saved.append(shortcut)
            case .removed(let id): removed.append(id)
            }
        }
        store.save(Shortcut(kind: .command, key: "ll", name: "", value: "ls"))
        let item = try #require(store.items.first)
        #expect(item.modified != nil)
        #expect(saved == [item])
        store.remove(item.id)
        #expect(removed == [item.id])
    }

    @Test func applyRemoteDoesNotReportAndResolvesKeyConflicts() throws {
        let suite = "turm.sync.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostStore(defaults: defaults)
        var reports = 0
        store.onChange = { _ in reports += 1 }
        store.save(SSHHost(key: "prod", hostname: "local.example.com"))
        store.applyRemote([SSHHost(key: "prod", hostname: "remote.example.com", modified: Date())], removing: [])
        #expect(reports == 1)
        #expect(store.hosts.count == 2)
        #expect(Set(store.hosts.map(\.key)) == ["prod", "prod2"])
    }
}
