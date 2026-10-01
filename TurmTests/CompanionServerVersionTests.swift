import Foundation
import Network
import Testing
import TurmCore
@testable import Turm

// drives the Mac's real hello handling with phones built from other releases
@MainActor
@Suite(.serialized)
struct CompanionServerVersionTests {
    private final class Phone {
        let id = UUID()
        let key = CompanionCrypto.generateSecret()
        let server = CompanionServer()
        let keychain = CompanionKeychain(role: .mac, service: "app.turm.companion.tests." + UUID().uuidString)
        var sent: [CompanionMessage] = []
        var peer: CompanionPeer!

        init(mac: CompanionVersion = .current, paired: Bool = true) throws {
            server.localVersion = mac
            server.devices = PairedDevices(keychain: keychain)
            if paired { try server.devices.add(id: id, name: "Test Phone", key: key) }
            let connection = try #require(CompanionConnection(host: "127.0.0.1", port: 1, parameters: .tcp))
            peer = CompanionPeer(connection: connection, sink: { [unowned self] in
                sent.append($0)
                return true
            })
        }

        func hello(_ version: CompanionVersion) {
            let proof = CompanionCrypto.helloProof(key: key, deviceID: id)
            server.received(.hello(version: version, deviceID: id, name: "Test Phone", proof: proof), from: peer)
        }

        var notice: CompanionServer.UpdateNotice? { server.updateNotices[id] }

        func finish() {
            server.drop(peer)
            keychain.removeAll()
        }
    }

    private func build(adding extra: Set<String> = [], removing gone: Set<String> = [], essential: Set<String> = [], app: String) -> CompanionVersion {
        let current = CompanionVersion.current
        return CompanionVersion(
            app: app, kinds: current.kinds.union(extra).subtracting(gone), essential: current.essential.union(essential).subtracting(gone)
        )
    }

    @Test func aMatchingPhoneIsWelcomedAndToldWhereToFindTheMac() throws {
        let phone = try Phone()
        defer { phone.finish() }
        phone.hello(.current)
        #expect(phone.sent.first == .welcome(version: .current, macName: phone.server.macName))
        #expect(phone.sent.contains(phone.server.addresses))
        #expect(phone.peer.stage == .authenticated)
        #expect(phone.notice == nil)
    }

    @Test func aPhoneMissingAnEssentialMessageIsRefusedAndNamedOutdated() throws {
        let mac = build(app: "1.5.0")
        let phone = try Phone(mac: mac)
        defer { phone.finish() }
        phone.hello(build(removing: ["snapshot"], app: "1.3.0"))
        #expect(phone.sent == [.incompatible(version: mac)])
        #expect(phone.peer.stage != .authenticated)
        #expect(phone.notice?.macIsOutdated == false)
        #expect(phone.notice?.text.contains("Update Turm on Test Phone") == true)
    }

    @Test func aPhoneRequiringWhatThisMacLacksIsRefusedAndTheMacIsNamedOutdated() throws {
        let phone = try Phone(mac: build(app: "1.4.0"))
        defer { phone.finish() }
        phone.hello(build(adding: ["futureFeature"], essential: ["futureFeature"], app: "2.0.0"))
        #expect(phone.sent.first.map { if case .incompatible = $0 { true } else { false } } == true)
        #expect(phone.notice?.macIsOutdated == true)
        #expect(phone.notice?.text.contains("Update Turm on this Mac") == true)
    }

    @Test func aNewerPhoneWithOptionalExtrasConnectsAndSuggestsUpdatingTheMac() throws {
        let phone = try Phone(mac: build(app: "1.4.0"))
        defer { phone.finish() }
        phone.hello(build(adding: ["futureFeature"], app: "1.6.0"))
        #expect(phone.peer.stage == .authenticated)
        #expect(phone.notice?.macIsOutdated == true)
    }

    @Test func messagesTheOlderPhoneCannotReadAreNeverSent() throws {
        let phone = try Phone()
        defer { phone.finish() }
        phone.hello(build(removing: ["addresses"], app: "1.3.0"))
        #expect(phone.peer.stage == .authenticated)
        #expect(!phone.sent.contains { $0.kind == .addresses })
        #expect(phone.notice?.macIsOutdated == false)
    }

    @Test func anUnpairedDeviceLearnsNothingAndLeavesNoNotice() throws {
        let phone = try Phone(paired: false)
        defer { phone.finish() }
        phone.hello(.current)
        #expect(phone.sent.first.map { if case .error(CompanionErrorCode.unauthorized, _) = $0 { true } else { false } } == true)
        phone.hello(build(removing: ["snapshot"], app: "0.1"))
        #expect(phone.notice == nil)
    }
}
