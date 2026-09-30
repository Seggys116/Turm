import Foundation
import Observation

nonisolated struct SSHHost: Codable, Equatable, Identifiable, Sendable {
    static let sigil: Character = ">"

    var id = UUID()
    var key: String
    var hostname: String
    var user = ""
    var port: Int?
    var identityFile: String?
    var remembersPassword = false
    var sudoFill = SudoFill.off

    enum SudoFill: String, Codable, CaseIterable, Sendable {
        case off
        case ask
        case automatic
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, hostname, user, port, identityFile, remembersPassword, sudoFill
    }

    init(
        id: UUID = UUID(), key: String, hostname: String, user: String = "", port: Int? = nil,
        identityFile: String? = nil, remembersPassword: Bool = false, sudoFill: SudoFill = .off
    ) {
        self.id = id
        self.key = key
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remembersPassword = remembersPassword
        self.sudoFill = sudoFill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        hostname = try container.decode(String.self, forKey: .hostname)
        user = try container.decode(String.self, forKey: .user)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        remembersPassword = try container.decode(Bool.self, forKey: .remembersPassword)
        sudoFill = (try? container.decodeIfPresent(SudoFill.self, forKey: .sudoFill)) ?? .off
    }

    var token: String { String(Self.sigil) + key }

    var destination: String { user.isEmpty ? hostname : user + "@" + hostname }

    var summary: String {
        destination + (port.map { ":\($0)" } ?? "")
    }

    func matches(_ target: SSHTarget) -> Bool {
        guard hostname.caseInsensitiveCompare(target.hostname) == .orderedSame
            || key.caseInsensitiveCompare(target.hostname) == .orderedSame
        else { return false }
        if !user.isEmpty, user != target.user { return false }
        return (port ?? 22) == target.port
    }
}

nonisolated struct SSHTarget: Equatable, Hashable, Sendable {
    var user: String
    var hostname: String
    var port: Int

    var identifier: String { "\(user)@\(hostname):\(port)" }

    init(user: String, hostname: String, port: Int) {
        self.user = user
        self.hostname = hostname
        self.port = port
    }

    init?(identifier: String) {
        guard let at = identifier.lastIndex(of: "@"), let colon = identifier.lastIndex(of: ":"), at < colon,
              let port = Int(identifier[identifier.index(after: colon)...])
        else { return nil }
        let host = String(identifier[identifier.index(after: at)..<colon])
        guard !host.isEmpty else { return nil }
        self.init(user: String(identifier[..<at]), hostname: host, port: port)
    }

    static func resolved(from config: String) -> SSHTarget? {
        var values: [String: String] = [:]
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            if ["user", "hostname", "port"].contains(name), values[name] == nil { values[name] = String(parts[1]) }
        }
        guard let host = values["hostname"], let user = values["user"], let port = values["port"].flatMap(Int.init) else { return nil }
        return SSHTarget(user: user, hostname: host, port: port)
    }
}

nonisolated struct SSHRoute: Equatable, Sendable {
    let token: String
    let remainder: String
    let host: SSHHost?

    static func isRoute(_ line: String) -> Bool {
        line.drop(while: \.isWhitespace).first == SSHHost.sigil
    }

    static func parse(_ line: String, hosts: [SSHHost]) -> SSHRoute? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == SSHHost.sigil else { return nil }
        let body = trimmed.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        guard !token.isEmpty, token.allSatisfy(isDestinationCharacter) else { return nil }
        let remainder = body.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        let host = hosts.first { $0.key.caseInsensitiveCompare(token) == .orderedSame }
        return SSHRoute(token: token, remainder: remainder, host: host)
    }

    static func partial(_ prefix: String) -> String? {
        let body = prefix.drop(while: \.isWhitespace)
        guard body.first == SSHHost.sigil else { return nil }
        let typed = body.dropFirst()
        guard typed.allSatisfy(isDestinationCharacter) else { return nil }
        return String(typed)
    }

    static func isDestinationCharacter(_ character: Character) -> Bool {
        Shortcuts.isKeyCharacter(character) || character == "@" || character == ":" || character == "[" || character == "]"
    }

    func command(remote: Bool, quote: (String) -> String) -> String {
        var words = ["ssh"]
        if let host {
            if let port = host.port { words += ["-p", String(port)] }
            if !remote, let identity = host.identityFile, !identity.isEmpty {
                words += ["-i", quote(identity), "-o", "IdentitiesOnly=yes"]
            }
            let destination = host.hostname.isEmpty ? host.key : host.destination
            words.append(quote(destination))
        } else {
            let parsed = Self.split(token)
            if let port = parsed.port { words += ["-p", String(port)] }
            words.append(quote(parsed.destination))
        }
        if !remainder.isEmpty { words.append(remainder) }
        return words.joined(separator: " ")
    }

    static func split(_ token: String) -> (destination: String, port: Int?) {
        if token.hasPrefix("["), let close = token.firstIndex(of: "]") {
            let host = String(token[token.index(after: token.startIndex)..<close])
            let rest = token[token.index(after: close)...]
            return (host, rest.first == ":" ? Int(rest.dropFirst()) : nil)
        }
        let atEnd = token.lastIndex(of: "@").map(token.index(after:)) ?? token.startIndex
        let hostPart = token[atEnd...]
        guard let colon = hostPart.lastIndex(of: ":"), hostPart.firstIndex(of: ":") == colon,
              let port = Int(hostPart[hostPart.index(after: colon)...])
        else { return (token, nil) }
        return (String(token[..<colon]), port)
    }
}

@Observable
final class SSHHostStore {
    static let shared = SSHHostStore()
    nonisolated static let hostsKey = "turm.sshHosts"
    static let declinedKey = "turm.sshDeclined"
    static let offerKey = "turm.sshOfferIntegration"

    private(set) var hosts: [SSHHost]
    private(set) var declined: [String]
    @ObservationIgnored private let defaults: UserDefaults

    nonisolated static func load(from defaults: UserDefaults = .standard) -> [SSHHost] {
        guard let data = defaults.string(forKey: hostsKey)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = Self.load(from: defaults)
        declined = defaults.stringArray(forKey: Self.declinedKey) ?? []
    }

    var offersIntegration: Bool {
        get { defaults.object(forKey: Self.offerKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.offerKey) }
    }

    func host(matching target: SSHTarget) -> SSHHost? {
        hosts.first { $0.matches(target) }
    }

    func draft(for target: SSHTarget) -> SSHHost {
        let first = target.hostname.split(separator: ".").first.map(String.init) ?? target.hostname
        let base = Shortcuts.sanitize(first).lowercased()
        var key = base.isEmpty ? "host" : base
        var number = 2
        while conflict(for: key, excluding: nil) != nil {
            key = (base.isEmpty ? "host" : base) + String(number)
            number += 1
        }
        return SSHHost(key: key, hostname: target.hostname, user: target.user, port: target.port == 22 ? nil : target.port)
    }

    func conflict(for key: String, excluding id: UUID?) -> SSHHost? {
        hosts.first { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.id != id }
    }

    @discardableResult
    func save(_ host: SSHHost) -> Bool {
        var entry = host
        entry.key = Shortcuts.sanitize(host.key)
        entry.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identity = entry.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) {
            entry.identityFile = identity.isEmpty ? nil : identity
        }
        if let port = entry.port, !(1...65535).contains(port) { entry.port = nil }
        guard !entry.key.isEmpty, !entry.hostname.isEmpty, conflict(for: entry.key, excluding: entry.id) == nil else { return false }
        if let index = hosts.firstIndex(where: { $0.id == entry.id }) {
            hosts[index] = entry
        } else {
            hosts.append(entry)
        }
        if !entry.remembersPassword { SSHSecrets.shared.forgetStored(for: entry.id) }
        persist()
        return true
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        SSHSecrets.shared.forget(id)
        persist()
    }

    func isDeclined(_ target: SSHTarget) -> Bool {
        declined.contains(target.identifier)
    }

    func decline(_ target: SSHTarget) {
        guard !declined.contains(target.identifier) else { return }
        declined.append(target.identifier)
        defaults.set(declined, forKey: Self.declinedKey)
    }

    func allow(_ identifier: String) {
        declined.removeAll { $0 == identifier }
        defaults.set(declined, forKey: Self.declinedKey)
    }

    func importable(from configHosts: [String]) -> [String] {
        configHosts.filter { name in !hosts.contains { $0.key.caseInsensitiveCompare(name) == .orderedSame } }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.hostsKey)
        NotificationCenter.default.post(name: .completionEnvironmentChanged, object: nil)
    }
}
