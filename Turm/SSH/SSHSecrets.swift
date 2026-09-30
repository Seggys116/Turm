import Foundation
import Security

final class SSHSecrets {
    static let shared = SSHSecrets()
    static let service = "app.turm.ssh"

    private var memory: [UUID: String] = [:]
    private let service: String

    init(service: String = SSHSecrets.service) {
        self.service = service
    }

    func password(for host: SSHHost) -> String? {
        if let held = memory[host.id] { return held }
        guard host.remembersPassword else { return nil }
        return stored(for: host.id)
    }

    func hasPassword(for host: SSHHost) -> Bool {
        memory[host.id] != nil || (host.remembersPassword && stored(for: host.id) != nil)
    }

    @discardableResult
    func set(_ password: String, for host: SSHHost) -> Bool {
        guard !password.isEmpty else {
            forget(host.id)
            return true
        }
        guard host.remembersPassword else {
            memory[host.id] = password
            forgetStored(for: host.id)
            return true
        }
        memory[host.id] = nil
        return store(password, for: host.id)
    }

    func forget(_ id: UUID) {
        memory[id] = nil
        forgetStored(for: id)
    }

    func forgetStored(for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private func stored(for id: UUID) -> String? {
        var lookup = query(for: id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func store(_ password: String, for id: UUID) -> Bool {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: id) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(for: id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Turm SSH password"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

nonisolated enum SSHPasswordPrompt {
    static func matches(_ tail: String, target: SSHTarget) -> Bool {
        let line = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasSuffix("password:") else { return false }
        let host = target.hostname.lowercased()
        let user = target.user.lowercased()
        let owners = ["\(user)@\(host)'s password:", "(\(user)@\(host)) password:"]
        return owners.contains(lower)
    }
}
