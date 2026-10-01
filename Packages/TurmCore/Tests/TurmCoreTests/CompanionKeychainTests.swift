import Foundation
import Testing
@testable import TurmCore

struct CompanionKeychainTests {
    private func store() -> CompanionKeychain {
        CompanionKeychain(role: .mac, service: "app.turm.companion.tests." + UUID().uuidString)
    }

    @Test func savesReadsAndRemoves() throws {
        let keychain = store()
        defer { keychain.removeAll() }
        let record = CompanionPeerRecord(id: UUID(), name: "Phone", key: CompanionCrypto.generateSecret(), hosts: ["10.0.0.2"], port: 7337)
        try keychain.save(record)
        #expect(keychain.record(for: record.id) == record)
        #expect(keychain.all().map(\.id) == [record.id])
        keychain.remove(record.id)
        #expect(keychain.all().isEmpty)
    }

    @Test func updatingReplacesTheRecord() throws {
        let keychain = store()
        defer { keychain.removeAll() }
        var record = CompanionPeerRecord(id: UUID(), name: "Phone", key: CompanionCrypto.generateSecret())
        try keychain.save(record)
        record.name = "Renamed"
        try keychain.save(record)
        #expect(keychain.all().map(\.name) == ["Renamed"])
    }

    @Test func rolesUseSeparateServices() {
        #expect(CompanionKeychain.Role.mac.service != CompanionKeychain.Role.phone.service)
    }
}
