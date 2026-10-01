import Foundation
import Security

public nonisolated enum SecretsMigration {
    @discardableResult
    public static func runIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        #if os(macOS)
        guard !defaults.bool(forKey: SyncPreference.migratedKey) else { return true }
        let target = KeychainItem(service: SSHSecrets.service)
        guard target.config.dataProtection else { return false }
        let accounts = legacyAccounts(service: SSHSecrets.service)
        var complete = true
        for account in accounts {
            guard let data = legacyData(service: SSHSecrets.service, account: account),
                  target.write(account, data: data, label: label(for: account)),
                  target.read(account) == data
            else {
                complete = false
                continue
            }
            SecItemDelete(legacyQuery(service: SSHSecrets.service, account: account) as CFDictionary)
        }
        if complete { defaults.set(true, forKey: SyncPreference.migratedKey) }
        return complete
        #else
        return true
        #endif
    }

    #if os(macOS)
    private static func label(for account: String) -> String {
        account.hasSuffix(".sudo") ? "Turm sudo password" : "Turm SSH password"
    }

    private static func legacyQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func legacyAccounts(service: String) -> [String] {
        var query = legacyQuery(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func legacyData(service: String, account: String) -> Data? {
        var query = legacyQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    #endif
}
