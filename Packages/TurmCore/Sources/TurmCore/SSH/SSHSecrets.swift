import Foundation
import Security

public final class SSHSecrets {
    public enum Slot: CaseIterable {
        case login
        case sudo

        fileprivate func account(for id: UUID) -> String {
            self == .login ? id.uuidString : id.uuidString + ".sudo"
        }
    }

    public static let shared = SSHSecrets()
    public static let service = "app.turm.ssh"

    private var memory: [String: String] = [:]
    private let backing: any SecretBacking

    public convenience init(service: String = SSHSecrets.service) {
        self.init(backing: KeychainItem(service: service))
    }

    init(backing: any SecretBacking) {
        self.backing = backing
    }

    public func password(for host: SSHHost, slot: Slot = .login) -> String? {
        if let held = memory[slot.account(for: host.id)] { return held }
        guard host.remembersPassword else { return nil }
        return stored(slot.account(for: host.id))
    }

    public func hasPassword(for host: SSHHost, slot: Slot = .login) -> Bool {
        memory[slot.account(for: host.id)] != nil || (host.remembersPassword && stored(slot.account(for: host.id)) != nil)
    }

    public func sudoPassword(for host: SSHHost) -> String? {
        password(for: host, slot: .sudo) ?? password(for: host)
    }

    @discardableResult
    public func set(_ password: String, for host: SSHHost, slot: Slot = .login) -> Bool {
        let account = slot.account(for: host.id)
        guard !password.isEmpty else {
            memory[account] = nil
            backing.remove(account)
            return true
        }
        guard host.remembersPassword else {
            memory[account] = password
            backing.remove(account)
            return true
        }
        memory[account] = nil
        return store(password, for: account, label: slot == .login ? "Turm SSH password" : "Turm sudo password")
    }

    public func forget(_ id: UUID, slot: Slot) {
        memory[slot.account(for: id)] = nil
        backing.remove(slot.account(for: id))
    }

    public func forget(_ id: UUID) {
        Slot.allCases.forEach { forget(id, slot: $0) }
    }

    public func forgetStored(for id: UUID) {
        for slot in Slot.allCases { backing.remove(slot.account(for: id)) }
    }

    private func stored(_ account: String) -> String? {
        backing.read(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func store(_ password: String, for account: String, label: String) -> Bool {
        backing.write(account, data: Data(password.utf8), label: label)
    }
}
