import Foundation
import Observation

public nonisolated struct SSHHost: Codable, Equatable, Identifiable, Sendable {
    public static let sigil: Character = ">"

    public var id = UUID()
    public var key: String
    public var hostname: String
    public var user = ""
    public var port: Int?
    public var identityFile: String?
    public var remembersPassword = false
    public var sudoFill = SudoFill.off
    public var identityKeyID: UUID?
    public var modified: Date?

    public enum SudoFill: String, Codable, CaseIterable, Sendable {
        case off
        case ask
        case automatic
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, hostname, user, port, identityFile, remembersPassword, sudoFill, identityKeyID, modified
    }

    public init(
        id: UUID = UUID(), key: String, hostname: String, user: String = "", port: Int? = nil,
        identityFile: String? = nil, remembersPassword: Bool = false, sudoFill: SudoFill = .off,
        identityKeyID: UUID? = nil, modified: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remembersPassword = remembersPassword
        self.sudoFill = sudoFill
        self.identityKeyID = identityKeyID
        self.modified = modified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        hostname = try container.decode(String.self, forKey: .hostname)
        user = try container.decode(String.self, forKey: .user)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        remembersPassword = try container.decode(Bool.self, forKey: .remembersPassword)
        sudoFill = (try? container.decodeIfPresent(SudoFill.self, forKey: .sudoFill)) ?? .off
        identityKeyID = try container.decodeIfPresent(UUID.self, forKey: .identityKeyID)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified)
    }

    public var token: String { String(Self.sigil) + key }

    public var destination: String { user.isEmpty ? hostname : user + "@" + hostname }

    public var summary: String {
        destination + (port.map { ":\($0)" } ?? "")
    }

    public func matches(_ target: SSHTarget) -> Bool {
        guard hostname.caseInsensitiveCompare(target.hostname) == .orderedSame
            || key.caseInsensitiveCompare(target.hostname) == .orderedSame
        else { return false }
        if !user.isEmpty, user != target.user { return false }
        return (port ?? 22) == target.port
    }
}

// host fields reach ssh's argument list, so anything ssh could parse as an option or a second word is refused
public nonisolated enum SSHHostValidation {
    public static func normalized(_ host: SSHHost) -> SSHHost? {
        var entry = host
        entry.key = Shortcuts.sanitize(host.key)
        entry.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identity = entry.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) {
            entry.identityFile = identity.isEmpty ? nil : identity
        }
        guard !entry.key.isEmpty, !entry.hostname.isEmpty,
              isSafeWord(entry.hostname), isSafeWord(entry.user), !entry.user.contains("@")
        else { return nil }
        if let port = entry.port, !(1...65535).contains(port) { return nil }
        if let identity = entry.identityFile, identity.hasPrefix("-") || hasControl(identity) { return nil }
        return entry
    }

    public static func problem(_ host: SSHHost) -> String? {
        let hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = host.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hostname.hasPrefix("-") { return "The host cannot start with a dash." }
        if !isSafeWord(hostname) { return "The host cannot contain spaces or control characters." }
        if user.hasPrefix("-") { return "The user cannot start with a dash." }
        if user.contains("@") { return "The user cannot contain @." }
        if !isSafeWord(user) { return "The user cannot contain spaces or control characters." }
        if let port = host.port, !(1...65535).contains(port) { return "The port must be a number from 1 to 65535." }
        if identity.hasPrefix("-") { return "The key path cannot start with a dash." }
        if hasControl(identity) { return "The key path cannot contain control characters." }
        return nil
    }

    private static func isSafeWord(_ text: String) -> Bool {
        !text.hasPrefix("-") && !hasControl(text) && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.value == 0 }
    }
}

public nonisolated struct SSHTarget: Equatable, Hashable, Sendable {
    public var user: String
    public var hostname: String
    public var port: Int

    public var identifier: String { "\(user)@\(hostname):\(port)" }

    public init(user: String, hostname: String, port: Int) {
        self.user = user
        self.hostname = hostname
        self.port = port
    }

    public init?(identifier: String) {
        guard let at = identifier.lastIndex(of: "@"), let colon = identifier.lastIndex(of: ":"), at < colon,
              let port = Int(identifier[identifier.index(after: colon)...])
        else { return nil }
        let host = String(identifier[identifier.index(after: at)..<colon])
        guard !host.isEmpty else { return nil }
        self.init(user: String(identifier[..<at]), hostname: host, port: port)
    }

    public static func resolved(from config: String) -> SSHTarget? {
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

public nonisolated struct SSHRoute: Equatable, Sendable {
    public let token: String
    public let remainder: String
    public let host: SSHHost?

    public init(token: String, remainder: String, host: SSHHost?) {
        self.token = token
        self.remainder = remainder
        self.host = host
    }

    public static func isRoute(_ line: String) -> Bool {
        line.drop(while: \.isWhitespace).first == SSHHost.sigil
    }

    public static func parse(_ line: String, hosts: [SSHHost]) -> SSHRoute? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == SSHHost.sigil else { return nil }
        let body = trimmed.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        guard !token.isEmpty, token.allSatisfy(isDestinationCharacter) else { return nil }
        let remainder = body.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        let host = hosts.first { $0.key.caseInsensitiveCompare(token) == .orderedSame }
        return SSHRoute(token: token, remainder: remainder, host: host)
    }

    public static func partial(_ prefix: String) -> String? {
        let body = prefix.drop(while: \.isWhitespace)
        guard body.first == SSHHost.sigil else { return nil }
        let typed = body.dropFirst()
        guard typed.allSatisfy(isDestinationCharacter) else { return nil }
        return String(typed)
    }

    public static func isDestinationCharacter(_ character: Character) -> Bool {
        Shortcuts.isKeyCharacter(character) || character == "@" || character == ":" || character == "[" || character == "]"
    }

    public func command(remote: Bool, quote: (String) -> String) -> String {
        var words = ["ssh"]
        if let host {
            if let port = host.port { words += ["-p", String(port)] }
            if !remote, let identity = host.identityFile, !identity.isEmpty {
                words += ["-i", quote(identity), "-o", "IdentitiesOnly=yes"]
            }
            let destination = host.hostname.isEmpty ? host.key : host.destination
            words += ["--", quote(destination)]
        } else {
            let parsed = Self.split(token)
            if let port = parsed.port { words += ["-p", String(port)] }
            words += ["--", quote(parsed.destination)]
        }
        if !remainder.isEmpty { words.append(remainder) }
        return words.joined(separator: " ")
    }

    public static func split(_ token: String) -> (destination: String, port: Int?) {
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
public final class SSHHostStore {
    public static let shared = SSHHostStore()
    public nonisolated static let hostsKey = "turm.sshHosts"
    public static let declinedKey = "turm.sshDeclined"
    public static let offerKey = "turm.sshOfferIntegration"

    public private(set) var hosts: [SSHHost]
    public private(set) var declined: [String]
    @ObservationIgnored public var onChange: ((RecordChange<SSHHost>) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public nonisolated static func load(from defaults: UserDefaults = .standard) -> [SSHHost] {
        guard let data = defaults.string(forKey: hostsKey)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = Self.load(from: defaults)
        declined = defaults.stringArray(forKey: Self.declinedKey) ?? []
    }

    public var offersIntegration: Bool {
        get { defaults.object(forKey: Self.offerKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.offerKey) }
    }

    public func host(matching target: SSHTarget) -> SSHHost? {
        hosts.first { $0.matches(target) }
    }

    public func draft(for target: SSHTarget) -> SSHHost {
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

    public func conflict(for key: String, excluding id: UUID?) -> SSHHost? {
        hosts.first { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.id != id }
    }

    @discardableResult
    public func save(_ host: SSHHost) -> Bool {
        var draft = host
        if let port = draft.port, !(1...65535).contains(port) { draft.port = nil }
        guard var entry = SSHHostValidation.normalized(draft), conflict(for: entry.key, excluding: entry.id) == nil else { return false }
        entry.modified = Date()
        if let index = hosts.firstIndex(where: { $0.id == entry.id }) {
            hosts[index] = entry
        } else {
            hosts.append(entry)
        }
        if !entry.remembersPassword { SSHSecrets.shared.forgetStored(for: entry.id) }
        persist()
        onChange?(.saved(entry))
        return true
    }

    public func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        SSHSecrets.shared.forget(id)
        persist()
        onChange?(.removed(id))
    }

    // applied without reporting back, so remote records do not echo to the cloud
    public func applyRemote(_ incoming: [SSHHost], removing removed: [UUID]) {
        guard !incoming.isEmpty || !removed.isEmpty else { return }
        for id in removed {
            hosts.removeAll { $0.id == id }
            SSHSecrets.shared.forget(id)
        }
        for incomingHost in incoming {
            guard var host = SSHHostValidation.normalized(incomingHost) else { continue }
            let base = host.key
            var number = 2
            while conflict(for: host.key, excluding: host.id) != nil {
                host.key = base + String(number)
                number += 1
            }
            if let index = hosts.firstIndex(where: { $0.id == host.id }) {
                hosts[index] = host
            } else {
                hosts.append(host)
            }
        }
        persist()
    }

    public func isDeclined(_ target: SSHTarget) -> Bool {
        declined.contains(target.identifier)
    }

    public func decline(_ target: SSHTarget) {
        guard !declined.contains(target.identifier) else { return }
        declined.append(target.identifier)
        defaults.set(declined, forKey: Self.declinedKey)
    }

    public func allow(_ identifier: String) {
        declined.removeAll { $0 == identifier }
        defaults.set(declined, forKey: Self.declinedKey)
    }

    public func importable(from configHosts: [String]) -> [String] {
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
