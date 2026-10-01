import Foundation
import Network
import Security

public nonisolated struct CompanionPeerRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var key: Data
    public var created: Date
    public var hosts: [String]
    public var port: UInt16

    public init(id: UUID, name: String, key: Data, created: Date = Date(), hosts: [String] = [], port: UInt16 = 0) {
        self.id = id
        self.name = name
        self.key = key
        self.created = created
        self.hosts = hosts
        self.port = port
    }

    // the address that just worked leads, then the Mac's own list; only stale private addresses are dropped
    @discardableResult
    public mutating func learn(hosts reported: [String], port reportedPort: UInt16, via used: String?) -> Bool {
        let kept = hosts.filter { !Self.isPrivateAddress($0) }
        var seen: Set<String> = []
        let merged = ([used].compactMap { $0 } + reported + kept)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let newPort = reportedPort == 0 ? port : reportedPort
        guard merged != hosts || newPort != port else { return false }
        hosts = merged
        port = newPort
        return true
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        if let v4 = IPv4Address(host) {
            let b = Array(v4.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 169 && b[1] == 254)
        }
        if let v6 = IPv6Address(host) {
            let first = v6.rawValue[v6.rawValue.startIndex]
            return first & 0xFE == 0xFC || (first == 0xFE && v6.rawValue[v6.rawValue.startIndex + 1] & 0xC0 == 0x80)
        }
        return false
    }
}

public nonisolated enum CompanionKeychainError: Error, Equatable {
    case status(OSStatus)
    case corrupt
}

// pairing keys stay in the data-protection keychain, readable only while unlocked, never synced
public nonisolated final class CompanionKeychain: @unchecked Sendable {
    public nonisolated enum Role: String, Sendable {
        case mac
        case phone

        var service: String {
            switch self {
            case .mac: "app.turm.companion.phones"
            case .phone: "app.turm.companion.macs"
            }
        }
    }

    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()
    private var memory: [String: Data]?

    public init(role: Role, service: String? = nil, accessGroup: String? = nil) {
        self.service = service ?? role.service
        self.accessGroup = accessGroup
        if !KeychainEntitlement.allowsDataProtection { memory = [:] }
    }

    public var isPersistent: Bool {
        lock.withLock { memory == nil }
    }

    public func all() -> [CompanionPeerRecord] {
        lock.withLock {
            if let memory { return memory.values.compactMap(decode).sorted(by: Self.order) }
            var query = baseQuery()
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecMissingEntitlement {
                memory = [:]
                return []
            }
            guard status == errSecSuccess, let items = result as? [Data] else { return [] }
            return items.compactMap(decode).sorted(by: Self.order)
        }
    }

    public func record(for id: UUID) -> CompanionPeerRecord? {
        lock.withLock {
            if let memory { return memory[id.uuidString].flatMap(decode) }
            var query = baseQuery(account: id.uuidString)
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return decode(data)
        }
    }

    public func save(_ record: CompanionPeerRecord) throws {
        let data = try JSONEncoder().encode(record)
        try lock.withLock {
            let account = record.id.uuidString
            if memory != nil {
                memory?[account] = data
                return
            }
            var status = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary
            )
            if status == errSecItemNotFound {
                var item = baseQuery(account: account)
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            if status == errSecMissingEntitlement {
                memory = [account: data]
                return
            }
            guard status == errSecSuccess else { throw CompanionKeychainError.status(status) }
        }
    }

    public func remove(_ id: UUID) {
        lock.withLock {
            if memory != nil {
                memory?[id.uuidString] = nil
                return
            }
            SecItemDelete(baseQuery(account: id.uuidString) as CFDictionary)
        }
    }

    public func removeAll() {
        lock.withLock {
            if memory != nil {
                memory = [:]
                return
            }
            SecItemDelete(baseQuery() as CFDictionary)
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func decode(_ data: Data) -> CompanionPeerRecord? {
        try? JSONDecoder().decode(CompanionPeerRecord.self, from: data)
    }

    private static func order(_ a: CompanionPeerRecord, _ b: CompanionPeerRecord) -> Bool {
        a.created < b.created
    }
}
