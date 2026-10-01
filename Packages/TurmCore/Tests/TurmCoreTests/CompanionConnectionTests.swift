import Foundation
import Network
import Testing
@testable import TurmCore

// real sockets on 127.0.0.1; needs no network access or permission
struct CompanionConnectionTests {
    private final class Loopback {
        let listener: NWListener
        var accepted: [CompanionConnection] = []
        var port: UInt16 = 0

        init(credentials: [CompanionTLS.Credential], reply: Bool, mac: CompanionVersion = .current) async throws {
            let parameters = CompanionTLS.serverParameters(credentials: credentials)
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
            let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
            listener.stateUpdateHandler = { continuation.yield($0) }
            listener.newConnectionHandler = { [unowned self] connection in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let peer = CompanionConnection(accepted: connection)
                        if reply {
                            peer.onMessage = { [weak peer] message in
                                if case .hello(let version, _, let name, _) = message {
                                    peer?.send(CompanionHandshake.answer(hello: version, local: mac, macName: "echo " + name).reply)
                                }
                            }
                        }
                        self.accepted.append(peer)
                        peer.start()
                    }
                }
            }
            listener.start(queue: .main)
            var bound: UInt16?
            for await state in states {
                if case .ready = state { bound = listener.port?.rawValue; break }
                if case .failed = state { break }
            }
            guard let bound else { throw CocoaError(.fileReadUnknown) }
            port = bound
        }

        deinit {
            listener.cancel()
        }

        func stop() {
            listener.cancel()
            accepted.forEach { $0.cancel() }
        }
    }

    private func next(_ stream: AsyncStream<CompanionMessage>, seconds: Double = 10) async -> CompanionMessage? {
        await withTaskGroup(of: CompanionMessage?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func reachesReady(_ states: AsyncStream<CompanionConnection.State>, seconds: Double = 8) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states {
                    switch state {
                    case .ready: return true
                    case .failed, .closed: return false
                    default: continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func connect(
        port: UInt16, identity: String, key: Data
    ) throws -> (CompanionConnection, AsyncStream<CompanionMessage>, AsyncStream<CompanionConnection.State>) {
        let parameters = CompanionTLS.clientParameters(identity: identity, key: key)
        guard let client = CompanionConnection(host: "127.0.0.1", port: port, parameters: parameters) else {
            throw CocoaError(.fileReadUnknown)
        }
        let (messages, messageSink) = AsyncStream.makeStream(of: CompanionMessage.self)
        let (states, stateSink) = AsyncStream.makeStream(of: CompanionConnection.State.self)
        client.onMessage = { messageSink.yield($0) }
        client.onState = { stateSink.yield($0) }
        return (client, messages, states)
    }

    @Test func handshakeAndHelloWelcome() async throws {
        let key = CompanionCrypto.generateSecret()
        let server = try await Loopback(credentials: [.init(identity: "device-a", key: key)], reply: true)
        defer { server.stop() }
        let (client, messages, _) = try connect(port: server.port, identity: "device-a", key: key)
        defer { client.cancel() }
        client.start()
        client.send(.hello(version: .current, deviceID: UUID(), name: "Phone", proof: Data()))
        #expect(await next(messages) == .welcome(version: .current, macName: "echo Phone"))
        #expect(client.negotiatedCipherSuite == CompanionTLS.forwardSecretSuite)
    }

    @Test func serverPicksTheKeyByIdentity() async throws {
        let first = CompanionCrypto.generateSecret()
        let second = CompanionCrypto.generateSecret()
        let server = try await Loopback(
            credentials: [.init(identity: "one", key: first), .init(identity: "two", key: second)], reply: true
        )
        defer { server.stop() }
        let (client, messages, _) = try connect(port: server.port, identity: "two", key: second)
        defer { client.cancel() }
        client.start()
        client.send(.ping)
        client.send(.hello(version: .current, deviceID: UUID(), name: "B", proof: Data()))
        #expect(await next(messages) == .welcome(version: .current, macName: "echo B"))
    }

    @Test func aWrongKeyNeverConnects() async throws {
        let server = try await Loopback(credentials: [.init(identity: "device-a", key: CompanionCrypto.generateSecret())], reply: true)
        defer { server.stop() }
        let (client, messages, states) = try connect(port: server.port, identity: "device-a", key: CompanionCrypto.generateSecret())
        defer { client.cancel() }
        client.start()
        client.send(.hello(version: .current, deviceID: UUID(), name: "Intruder", proof: Data()))
        #expect(await !reachesReady(states))
        #expect(await next(messages, seconds: 0.5) == nil)
    }

    @Test func anUnknownIdentityNeverConnects() async throws {
        let key = CompanionCrypto.generateSecret()
        let server = try await Loopback(credentials: [.init(identity: "device-a", key: key)], reply: true)
        defer { server.stop() }
        let (client, _, states) = try connect(port: server.port, identity: "someone-else", key: key)
        defer { client.cancel() }
        client.start()
        #expect(await !reachesReady(states))
    }

    private func handshake(mac: CompanionVersion, phone: CompanionVersion) async throws -> (CompanionMessage?, CompanionCompatibility?) {
        let key = CompanionCrypto.generateSecret()
        let server = try await Loopback(credentials: [.init(identity: "device-a", key: key)], reply: true, mac: mac)
        defer { server.stop() }
        let (client, messages, _) = try connect(port: server.port, identity: "device-a", key: key)
        defer { client.cancel() }
        client.start()
        client.send(.hello(version: phone, deviceID: UUID(), name: "Phone", proof: Data()))
        let reply = await next(messages)
        return (reply, reply.flatMap { CompanionHandshake.read($0, local: phone)?.compatibility })
    }

    private func build(adding extra: Set<String> = [], removing gone: Set<String> = [], essential: Set<String> = [], app: String) -> CompanionVersion {
        let current = CompanionVersion.current
        return CompanionVersion(
            app: app, kinds: current.kinds.union(extra).subtracting(gone),
            essential: current.essential.union(essential).subtracting(gone)
        )
    }

    @Test func matchingBuildsConnectWithNothingToUpdate() async throws {
        let (reply, result) = try await handshake(mac: .current, phone: .current)
        #expect(reply == .welcome(version: .current, macName: "echo Phone"))
        #expect(result == .compatible(outdated: nil))
    }

    @Test func aMacMissingAnEssentialMessageRefusesAndTheMacIsNamedOutdated() async throws {
        let mac = build(removing: ["snapshot"], app: "1.3.0")
        let phone = build(app: "1.5.0")
        let (reply, result) = try await handshake(mac: mac, phone: phone)
        #expect(reply == .incompatible(version: mac))
        #expect(result == .incompatible(outdated: .remote))
        let advice = result?.advice(local: phone, remote: mac, here: "this device", there: "Studio")
        #expect(advice?.contains("Update Turm on Studio") == true)
    }

    @Test func aNewerMacWithOptionalExtrasStillConnectsAndNamesThePhoneOutdated() async throws {
        let mac = build(adding: ["futureFeature"], app: "1.6.0")
        let phone = build(app: "1.5.0")
        let (reply, result) = try await handshake(mac: mac, phone: phone)
        #expect(reply == .welcome(version: mac, macName: "echo Phone"))
        #expect(result == .compatible(outdated: .local))
    }

    @Test func aNewerMacRequiringWhatThePhoneLacksRefusesAndNamesThePhone() async throws {
        let mac = build(adding: ["futureFeature"], essential: ["futureFeature"], app: "2.0.0")
        let phone = build(app: "1.5.0")
        let (reply, result) = try await handshake(mac: mac, phone: phone)
        #expect(reply == .incompatible(version: mac))
        #expect(result == .incompatible(outdated: .local))
    }

    @Test func aNewerPhoneTalkingToAnOlderMacNamesTheMac() async throws {
        let mac = build(app: "1.5.0")
        let phone = build(adding: ["futureFeature"], app: "1.6.0")
        let (reply, result) = try await handshake(mac: mac, phone: phone)
        #expect(reply == .welcome(version: mac, macName: "echo Phone"))
        #expect(result == .compatible(outdated: .remote))
    }
}
