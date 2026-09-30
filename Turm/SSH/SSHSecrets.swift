import Foundation
import Security

final class SSHSecrets {
    enum Slot: CaseIterable {
        case login
        case sudo

        fileprivate func account(for id: UUID) -> String {
            self == .login ? id.uuidString : id.uuidString + ".sudo"
        }
    }

    static let shared = SSHSecrets()
    static let service = "app.turm.ssh"

    private var memory: [String: String] = [:]
    private let service: String

    init(service: String = SSHSecrets.service) {
        self.service = service
    }

    func password(for host: SSHHost, slot: Slot = .login) -> String? {
        if let held = memory[slot.account(for: host.id)] { return held }
        guard host.remembersPassword else { return nil }
        return stored(slot.account(for: host.id))
    }

    func hasPassword(for host: SSHHost, slot: Slot = .login) -> Bool {
        memory[slot.account(for: host.id)] != nil || (host.remembersPassword && stored(slot.account(for: host.id)) != nil)
    }

    func sudoPassword(for host: SSHHost) -> String? {
        password(for: host, slot: .sudo) ?? password(for: host)
    }

    @discardableResult
    func set(_ password: String, for host: SSHHost, slot: Slot = .login) -> Bool {
        let account = slot.account(for: host.id)
        guard !password.isEmpty else {
            memory[account] = nil
            SecItemDelete(query(for: account) as CFDictionary)
            return true
        }
        guard host.remembersPassword else {
            memory[account] = password
            SecItemDelete(query(for: account) as CFDictionary)
            return true
        }
        memory[account] = nil
        return store(password, for: account, label: slot == .login ? "Turm SSH password" : "Turm sudo password")
    }

    func forget(_ id: UUID, slot: Slot) {
        memory[slot.account(for: id)] = nil
        SecItemDelete(query(for: slot.account(for: id)) as CFDictionary)
    }

    func forget(_ id: UUID) {
        Slot.allCases.forEach { forget(id, slot: $0) }
    }

    func forgetStored(for id: UUID) {
        for slot in Slot.allCases { SecItemDelete(query(for: slot.account(for: id)) as CFDictionary) }
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func stored(_ account: String) -> String? {
        var lookup = query(for: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func store(_ password: String, for account: String, label: String) -> Bool {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(for: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = label
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

nonisolated enum SudoPrompt {
    static func isSudo(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).first == "sudo"
    }

    static func matches(_ tail: String, user: String) -> Bool {
        guard !user.isEmpty, let line = tail.components(separatedBy: "\n").last else { return false }
        var trimmed = Substring(line)
        while trimmed.last == " " { trimmed.removeLast() }
        return trimmed == "[sudo] password for \(user):"
    }
}
