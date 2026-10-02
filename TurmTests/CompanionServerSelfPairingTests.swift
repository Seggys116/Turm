import Foundation
import Network
import Testing
import TurmCore
@testable import Turm

// drives the Mac's real pairing handling with a CompanionPairingClient over the peer sink seam
@MainActor
@Suite(.serialized)
struct CompanionServerSelfPairingTests {
    @MainActor
    private final class Harness {
        let server = CompanionServer()
        let keychain = CompanionKeychain(role: .mac, service: "app.turm.companion.tests." + UUID().uuidString)
        var sent: [CompanionMessage] = []
        var peer: CompanionPeer!
        private let savedEnabled = UserDefaults.standard.object(forKey: CompanionServer.enabledKey)
        private let savedPort = UserDefaults.standard.object(forKey: CompanionServer.portKey)

        init() throws {
            server.devices = PairedDevices(keychain: keychain)
            UserDefaults.standard.set(true, forKey: CompanionServer.enabledKey)
            UserDefaults.standard.set(Int.random(in: 40000...60000), forKey: CompanionServer.portKey)
            server.start()
            try #require(server.beginPairing())
            let connection = try #require(CompanionConnection(host: "127.0.0.1", port: 1, parameters: .tcp))
            peer = CompanionPeer(connection: connection, sink: { [unowned self] in
                sent.append($0)
                return true
            })
        }

        func pair(deviceID: UUID, bootstrap: CompanionBootstrap) throws -> CompanionMessage {
            var client = CompanionPairingClient(bootstrap: bootstrap, deviceID: deviceID, deviceName: "Other Mac")
            server.received(client.begin(), from: peer)
            let key = try #require(sent.last)
            guard case .confirm(_, let reveal) = client.receive(key) else {
                Issue.record("the client did not reach the confirm step")
                return key
            }
            server.received(reveal, from: peer)
            return try #require(sent.last)
        }

        func finish() {
            server.stop()
            keychain.removeAll()
            restore(CompanionServer.enabledKey, savedEnabled)
            restore(CompanionServer.portKey, savedPort)
        }

        private func restore(_ key: String, _ value: Any?) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func errorText(_ message: CompanionMessage) -> String? {
        if case .error(_, let text) = message { return text }
        return nil
    }

    @Test func qrPairingFromTheMacItselfIsRejectedAndStoresNothing() throws {
        let harness = try Harness()
        defer { harness.finish() }
        let window = try #require(harness.server.pairing)
        let reply = try harness.pair(deviceID: harness.server.macID, bootstrap: .qr(secret: window.payload.secret))
        #expect(errorText(reply) == "A Mac cannot pair with itself.")
        #expect(harness.server.devices.devices.isEmpty)
        #expect(harness.keychain.all().isEmpty)
    }

    @Test func codePairingFromTheMacItselfIsRejectedBeforeApprovalIsOffered() throws {
        let harness = try Harness()
        defer { harness.finish() }
        let window = try #require(harness.server.pairing)
        let reply = try harness.pair(deviceID: harness.server.macID, bootstrap: .code(window.code))
        #expect(errorText(reply) == "A Mac cannot pair with itself.")
        #expect(harness.server.pairing?.pending == nil)
        #expect(harness.server.devices.devices.isEmpty)
    }

    @Test func qrPairingFromAnotherDeviceStillSucceeds() throws {
        let harness = try Harness()
        defer { harness.finish() }
        let window = try #require(harness.server.pairing)
        let other = UUID()
        let reply = try harness.pair(deviceID: other, bootstrap: .qr(secret: window.payload.secret))
        guard case .pairDone = reply else {
            Issue.record("expected pairDone, got \(reply)")
            return
        }
        #expect(harness.server.devices.device(other) != nil)
    }
}
