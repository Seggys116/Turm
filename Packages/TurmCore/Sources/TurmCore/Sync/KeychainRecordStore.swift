import Foundation

final class KeychainRecordStore: SyncRecordStore {
    static let servicePrefix = "app.turm.sync."

    private let config: KeychainConfig

    init(config: KeychainConfig = KeychainItem.resolved) {
        self.config = config
    }

    var isAvailable: Bool { config.dataProtection }

    func accounts(in collection: String) -> [String] {
        item(collection).accounts(.synced)
    }

    func data(in collection: String, account: String) -> Data? {
        item(collection).read(account)
    }

    func set(_ data: Data, in collection: String, account: String) -> Bool {
        item(collection).write(account, data: data, label: "Turm sync")
    }

    func remove(in collection: String, account: String) {
        item(collection).remove(account)
    }

    func removeAll(in collection: String) {
        item(collection).deleteSynchronized()
    }

    private func item(_ collection: String) -> KeychainItem {
        KeychainItem(service: Self.servicePrefix + collection, config: config, syncEnabled: { true })
    }
}
