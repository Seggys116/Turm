import Foundation
import Observation

public nonisolated struct SSHIdentity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var algorithm: String
    public var publicKey: String
    public var created: Date

    public init(id: UUID = UUID(), name: String, algorithm: String, publicKey: String, created: Date = Date()) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.created = created
    }
}

extension SSHIdentity {
    /// The order OpenSSH tries default keys in: ed25519, then ECDSA, then RSA, others last; stable within a type.
    public nonisolated static func defaultOrder(_ identities: [SSHIdentity]) -> [SSHIdentity] {
        func rank(_ algorithm: String) -> Int {
            if algorithm == "ssh-ed25519" { return 0 }
            if algorithm.hasPrefix("ecdsa-") { return 1 }
            if algorithm == "ssh-rsa" { return 2 }
            return 3
        }
        return identities.enumerated()
            .sorted { (rank($0.element.algorithm), $0.offset) < (rank($1.element.algorithm), $1.offset) }
            .map(\.element)
    }
}

public nonisolated enum SSHIdentityError: Error, Equatable, LocalizedError {
    case unsupportedFormat
    case publicKeyOnly
    case tooLarge
    case malformed
    case storageFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Only OpenSSH private keys and RSA PEM keys are supported."
        case .publicKeyOnly: "This is a public key. Choose the private key file instead."
        case .tooLarge: "The file is too large to be an SSH private key."
        case .malformed: "The key file is damaged or incomplete."
        case .storageFailed: "The key could not be saved to the keychain."
        }
    }
}

public nonisolated struct SSHPrivateKeyInfo: Equatable, Sendable {
    public var algorithm: String
    public var publicKey: String
    public var encrypted: Bool
}

nonisolated struct ParsedPrivateKey: Equatable {
    var algorithm: String
    var publicKey: String
    var encrypted: Bool
}

nonisolated enum SSHPrivateKeyParser {
    private static let magic = Data("openssh-key-v1\0".utf8)

    static let sizeLimit = 64 * 1024

    static func parse(_ text: String) throws -> ParsedPrivateKey {
        guard text.utf8.count <= sizeLimit else { throw SSHIdentityError.tooLarge }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPublicKey(trimmed) { throw SSHIdentityError.publicKeyOnly }
        if let body = armored(trimmed, label: "OPENSSH PRIVATE KEY") { return try parseOpenSSH(body) }
        if let body = armored(trimmed, label: "RSA PRIVATE KEY") { return try parsePEM(body) }
        throw SSHIdentityError.unsupportedFormat
    }

    private static func isPublicKey(_ text: String) -> Bool {
        let prefixes = ["ssh-", "ecdsa-", "sk-", "-----BEGIN PUBLIC KEY", "-----BEGIN RSA PUBLIC KEY", "---- BEGIN SSH2 PUBLIC KEY"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private static func armored(_ text: String, label: String) -> String? {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard text.hasPrefix(begin), text.hasSuffix(end) else { return nil }
        return String(text.dropFirst(begin.count).dropLast(end.count))
    }

    private static func parsePEM(_ body: String) throws -> ParsedPrivateKey {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let encrypted = lines.contains { $0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED") }
        let payload = lines.filter { !$0.contains(":") }.joined()
        guard var raw = Data(base64Encoded: payload), !raw.isEmpty else { throw SSHIdentityError.malformed }
        defer { raw.resetBytes(in: 0..<raw.count) }
        guard encrypted || raw.first == 0x30 else { throw SSHIdentityError.malformed }
        return ParsedPrivateKey(algorithm: "ssh-rsa", publicKey: "", encrypted: encrypted)
    }

    private static func parseOpenSSH(_ body: String) throws -> ParsedPrivateKey {
        let payload = body.filter { !$0.isWhitespace }
        guard var raw = Data(base64Encoded: payload), raw.starts(with: magic) else { throw SSHIdentityError.malformed }
        defer { raw.resetBytes(in: 0..<raw.count) }
        var reader = Reader(data: raw, offset: magic.count)
        guard let cipher = reader.string(), reader.string() != nil, reader.string() != nil,
              reader.uint32() == 1, let blob = reader.string(), let sealed = reader.string(), !sealed.isEmpty,
              reader.offset == raw.count,
              let name = String(data: cipher, encoding: .utf8)
        else { throw SSHIdentityError.malformed }
        var inner = Reader(data: blob, offset: 0)
        guard let typeData = inner.string(), let algorithm = String(data: typeData, encoding: .utf8), !algorithm.isEmpty else {
            throw SSHIdentityError.malformed
        }
        return ParsedPrivateKey(algorithm: algorithm, publicKey: algorithm + " " + blob.base64EncodedString(), encrypted: name != "none")
    }

    private struct Reader {
        let data: Data
        var offset: Int

        mutating func uint32() -> UInt32? {
            guard data.count - offset >= 4 else { return nil }
            let start = data.startIndex + offset
            offset += 4
            return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> Data? {
            guard let length = uint32(), Int(length) <= data.count - offset else { return nil }
            let start = data.startIndex + offset
            offset += Int(length)
            return data[start..<start + Int(length)]
        }
    }
}

@Observable
public final class SSHIdentityStore {
    public static let shared = SSHIdentityStore()
    public nonisolated static let service = "app.turm.ssh.keys"
    public nonisolated static let defaultsKey = "turm.sshIdentities"

    public private(set) var identities: [SSHIdentity]
    @ObservationIgnored public var onChange: ((RecordChange<SSHIdentity>) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backing: any SecretBacking

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, backing: KeychainItem(service: Self.service))
    }

    init(defaults: UserDefaults, backing: any SecretBacking) {
        self.defaults = defaults
        self.backing = backing
        identities = Self.load(from: defaults)
    }

    /// Validates key text and reports what it is without storing anything.
    public nonisolated static func inspect(_ text: String) throws -> SSHPrivateKeyInfo {
        let parsed = try SSHPrivateKeyParser.parse(text)
        return SSHPrivateKeyInfo(algorithm: parsed.algorithm, publicKey: parsed.publicKey, encrypted: parsed.encrypted)
    }

    public func identity(_ id: UUID) -> SSHIdentity? {
        identities.first { $0.id == id }
    }

    public func privateKey(for id: UUID) -> String? {
        backing.read(Self.account(id, "key")).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func passphrase(for id: UUID) -> String? {
        backing.read(Self.account(id, "pass")).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public func importKey(name: String, privateKey: String, passphrase: String?) throws -> SSHIdentity {
        let parsed = try SSHPrivateKeyParser.parse(privateKey)
        let text = privateKey.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = SSHIdentity(
            name: trimmedName.isEmpty ? parsed.algorithm : trimmedName, algorithm: parsed.algorithm, publicKey: parsed.publicKey
        )
        var keyBytes = Data(text.utf8)
        var passBytes = Data((passphrase ?? "").utf8)
        defer {
            keyBytes.resetBytes(in: 0..<keyBytes.count)
            passBytes.resetBytes(in: 0..<passBytes.count)
        }
        guard backing.write(Self.account(identity.id, "key"), data: keyBytes, label: "Turm SSH key") else {
            throw SSHIdentityError.storageFailed
        }
        if !passBytes.isEmpty, !backing.write(Self.account(identity.id, "pass"), data: passBytes, label: "Turm SSH key passphrase") {
            backing.remove(Self.account(identity.id, "key"))
            throw SSHIdentityError.storageFailed
        }
        identities.append(identity)
        persist()
        onChange?(.saved(identity))
        return identity
    }

    @discardableResult
    public func setPassphrase(_ passphrase: String?, for id: UUID) -> Bool {
        guard identity(id) != nil else { return false }
        guard let passphrase, !passphrase.isEmpty else {
            backing.remove(Self.account(id, "pass"))
            return true
        }
        var bytes = Data(passphrase.utf8)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return backing.write(Self.account(id, "pass"), data: bytes, label: "Turm SSH key passphrase")
    }

    public func remove(_ id: UUID) {
        discardSecrets(id)
        identities.removeAll { $0.id == id }
        persist()
        onChange?(.removed(id))
    }

    // applied without reporting back, so remote records do not echo to the cloud
    func applyRemote(_ incoming: [SSHIdentity], removing removed: [UUID]) {
        guard !incoming.isEmpty || !removed.isEmpty else { return }
        for id in removed {
            discardSecrets(id)
            identities.removeAll { $0.id == id }
        }
        for identity in incoming where !identities.contains(where: { $0.id == identity.id }) {
            identities.append(identity)
        }
        persist()
    }

    private func discardSecrets(_ id: UUID) {
        backing.remove(Self.account(id, "key"))
        backing.remove(Self.account(id, "pass"))
    }

    private static func account(_ id: UUID, _ suffix: String) -> String {
        id.uuidString + "." + suffix
    }

    private nonisolated static func load(from defaults: UserDefaults) -> [SSHIdentity] {
        guard let data = defaults.string(forKey: defaultsKey)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SSHIdentity].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identities) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }
}
