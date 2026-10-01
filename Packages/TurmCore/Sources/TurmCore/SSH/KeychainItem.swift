import Foundation
import Security

nonisolated protocol SecretBacking: Sendable {
    func read(_ account: String) -> Data?
    func write(_ account: String, data: Data, label: String) -> Bool
    func remove(_ account: String)
}

nonisolated struct KeychainConfig: Sendable, Equatable {
    var dataProtection: Bool
    var accessGroup: String?
}

// falls back to the plain keychain when the process has no data-protection entitlement
nonisolated struct KeychainItem: SecretBacking {
    enum Scope {
        case any
        case local
        case synced
    }

    static let sharedGroupSuffix = "com.zak-noble-clarke.Turm.shared"
    static let resolved: KeychainConfig = probe()

    let service: String
    let config: KeychainConfig
    let syncEnabled: @Sendable () -> Bool

    init(
        service: String,
        config: KeychainConfig = KeychainItem.resolved,
        syncEnabled: @escaping @Sendable () -> Bool = { SyncPreference.isEnabled() }
    ) {
        self.service = service
        self.config = config
        self.syncEnabled = syncEnabled
    }

    func read(_ account: String) -> Data? {
        let order: [Scope] = config.dataProtection ? [.local, .synced] : [.any]
        for scope in order {
            if let data = data(account, scope: scope) { return data }
        }
        return nil
    }

    func write(_ account: String, data: Data, label: String) -> Bool {
        let synced = config.dataProtection && syncEnabled()
        let accessible = synced ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard upsert(account, data: data, label: label, scope: synced ? .synced : .local, accessible: accessible) else { return false }
        if synced { SecItemDelete(query(account: account, scope: .local) as CFDictionary) }
        return true
    }

    func remove(_ account: String) {
        SecItemDelete(query(account: account, scope: .any) as CFDictionary)
    }

    func accounts(_ scope: Scope) -> [String] {
        var lookup = query(account: nil, scope: scope)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func copySyncedToLocal() {
        guard config.dataProtection else { return }
        for account in accounts(.synced) where data(account, scope: .local) == nil {
            guard let value = data(account, scope: .synced) else { continue }
            _ = upsert(
                account, data: value, label: "Turm", scope: .local, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
        }
    }

    func promoteLocalToSynced() {
        guard config.dataProtection else { return }
        for account in accounts(.local) {
            guard let value = data(account, scope: .local),
                  upsert(account, data: value, label: "Turm", scope: .synced, accessible: kSecAttrAccessibleWhenUnlocked)
            else { continue }
            SecItemDelete(query(account: account, scope: .local) as CFDictionary)
        }
    }

    func deleteSynchronized() {
        guard config.dataProtection else { return }
        SecItemDelete(query(account: nil, scope: .synced) as CFDictionary)
    }

    private func data(_ account: String, scope: Scope) -> Data? {
        var lookup = query(account: account, scope: scope)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func upsert(_ account: String, data: Data, label: String, scope: Scope, accessible: CFString) -> Bool {
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        let status = SecItemUpdate(query(account: account, scope: scope) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(account: account, scope: scope)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = accessible
        item[kSecAttrLabel as String] = label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func query(account: String?, scope: Scope) -> [String: Any] {
        Self.query(service: service, account: account, scope: scope, config: config)
    }

    private static func query(service: String, account: String?, scope: Scope, config: KeychainConfig) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        guard config.dataProtection else { return query }
        query[kSecUseDataProtectionKeychain as String] = true
        if let group = config.accessGroup { query[kSecAttrAccessGroup as String] = group }
        switch scope {
        case .any: query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        case .local: query[kSecAttrSynchronizable as String] = false
        case .synced: query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private static func probe() -> KeychainConfig {
        let service = "app.turm.keychain.probe"
        let plain = KeychainConfig(dataProtection: true, accessGroup: nil)
        guard let group = defaultGroup(service: service, config: plain) else {
            return KeychainConfig(dataProtection: false, accessGroup: nil)
        }
        let prefix = group.split(separator: ".").first.map(String.init) ?? ""
        let shared = prefix + "." + sharedGroupSuffix
        if group == shared { return KeychainConfig(dataProtection: true, accessGroup: shared) }
        let candidate = KeychainConfig(dataProtection: true, accessGroup: shared)
        return defaultGroup(service: service, config: candidate) == nil ? plain : candidate
    }

    private static func defaultGroup(service: String, config: KeychainConfig) -> String? {
        var item = query(service: service, account: "probe", scope: .local, config: config)
        item[kSecValueData as String] = Data("probe".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        var status = SecItemAdd(item as CFDictionary, &result)
        if status == errSecDuplicateItem {
            var lookup = query(service: service, account: "probe", scope: .local, config: config)
            lookup[kSecReturnAttributes as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(lookup as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        SecItemDelete(query(service: service, account: "probe", scope: .local, config: config) as CFDictionary)
        return attributes[kSecAttrAccessGroup as String] as? String
    }
}
