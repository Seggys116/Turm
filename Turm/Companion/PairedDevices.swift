import Foundation
import Observation
import TurmCore

@Observable
final class PairedDevices {
    static let shared = PairedDevices()

    private(set) var devices: [CompanionPeerRecord]
    @ObservationIgnored private let keychain: CompanionKeychain

    init(keychain: CompanionKeychain = CompanionKeychain(role: .mac)) {
        self.keychain = keychain
        devices = keychain.all()
    }

    func device(_ id: UUID) -> CompanionPeerRecord? {
        devices.first { $0.id == id }
    }

    var credentials: [CompanionTLS.Credential] {
        devices.map { CompanionTLS.Credential(identity: $0.id.uuidString, key: $0.key) }
    }

    enum AddError: Error {
        case duplicate
    }

    func add(id: UUID, name: String, key: Data) throws {
        guard device(id) == nil else { throw AddError.duplicate }
        let record = CompanionPeerRecord(id: id, name: Self.clean(name), key: key)
        try keychain.save(record)
        devices.append(record)
    }

    func revoke(_ id: UUID) {
        keychain.remove(id)
        devices.removeAll { $0.id == id }
        CompanionServer.shared.deviceRevoked(id)
    }

    static func clean(_ name: String) -> String {
        let visible = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Phone" : String(trimmed.prefix(64))
    }
}
