import Foundation
import Network
import Observation
import TurmCore

private enum PairingFailure: Error {
    case unreachable
    case rejected(String)
    case timedOut
}

private struct PairedMac {
    let macID: UUID
    let macName: String
    let key: Data
    let host: String?
    let port: UInt16?
}

private final class PairingAttempt {
    private static let connectDeadline: Duration = .seconds(12)
    private static let approvalDeadline: Duration = .seconds(75)

    private var client: CompanionPairingClient
    private let connection: CompanionConnection
    private var continuation: CheckedContinuation<Result<PairedMac, PairingFailure>, Never>?
    private var timeout: Task<Void, Never>?
    private var reachedMac = false
    private var confirmed = false
    var onCode: ((String) -> Void)?

    init(endpoint: NWEndpoint, bootstrap: CompanionBootstrap) {
        client = CompanionPairingClient(bootstrap: bootstrap, deviceID: RemoteMacIdentity.id, deviceName: RemoteMacIdentity.name)
        connection = CompanionConnection(
            endpoint: endpoint,
            parameters: CompanionTLS.clientParameters(identity: bootstrap.identity, key: bootstrap.key)
        )
    }

    func run() async -> Result<PairedMac, PairingFailure> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            connection.onState = { [self] state in
                switch state {
                case .ready:
                    reachedMac = true
                    connection.send(client.begin())
                case .failed, .closed:
                    if confirmed {
                        finish(.failure(.rejected("Pairing was rejected or timed out on the other Mac.")))
                    } else if reachedMac {
                        finish(.failure(.rejected("The other Mac closed the connection before pairing finished.")))
                    } else if connection.tlsFailed {
                        finish(.failure(.rejected("The other Mac did not accept the code or link. Check it, and that pairing is open on that Mac.")))
                    } else {
                        finish(.failure(.unreachable))
                    }
                case .preparing, .waiting:
                    break
                }
            }
            connection.onMessage = { [self] message in
                switch client.receive(message) {
                case .confirm(let code, let reply):
                    connection.send(reply)
                    confirmed = true
                    startTimeout(Self.approvalDeadline)
                    onCode?(code)
                case .finished(let macID, let macName, let key):
                    let address = Self.address(of: connection.remoteEndpoint)
                    finish(.success(PairedMac(macID: macID, macName: macName, key: key, host: address?.host, port: address?.port)))
                case .failed(let text):
                    finish(.failure(.rejected(text)))
                }
            }
            startTimeout(Self.connectDeadline)
            connection.start()
        }
    }

    private func startTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            finish(.failure(confirmed ? .rejected("Pairing was rejected or timed out on the other Mac.") : .timedOut))
        }
    }

    // scoped IPv6 addresses are skipped because they would not work when reused later
    private static func address(of endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let value): text = "\(value)"
        case .ipv6(let value): text = "\(value)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        guard !text.isEmpty, !text.contains("%"), !text.lowercased().hasPrefix("fe80:") else { return nil }
        return (text, port.rawValue)
    }

    func cancel() {
        finish(.failure(.unreachable))
    }

    private func finish(_ result: Result<PairedMac, PairingFailure>) {
        guard let pending = continuation else { return }
        continuation = nil
        timeout?.cancel()
        connection.onState = nil
        connection.onMessage = nil
        connection.cancel()
        pending.resume(returning: result)
    }
}

@Observable
final class RemoteMacPairing {
    enum State: Equatable {
        case idle
        case working(String)
        case checking(code: String, macName: String)
        case done(String)
        case failed(String)
    }

    private static let selfMessage = "That is this Mac."

    private(set) var state = State.idle

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var current: PairingAttempt?

    var isWorking: Bool {
        switch state {
        case .working, .checking: true
        default: false
        }
    }

    func pair(payload: PairingPayload, manager: RemoteMacManager) {
        guard payload.macID != RemoteMacIdentity.id else {
            state = .failed(Self.selfMessage)
            return
        }
        guard !payload.isExpired() else {
            state = .failed("This link has expired. Copy a new one on the other Mac.")
            return
        }
        let port = NWEndpoint.Port(rawValue: payload.port)
        let endpoints = payload.hosts.compactMap { host in
            port.map { NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: $0) }
        }
        run(
            name: payload.macName, endpoints: endpoints, bootstrap: .qr(secret: payload.secret),
            hosts: payload.hosts, port: payload.port, expectedID: payload.macID, manager: manager
        )
    }

    func pair(link: String, manager: RemoteMacManager) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let payload = PairingPayload(url: url) else {
            state = .failed("That is not a Turm pairing link. Copy the turm-pair:// link from Pair a Device on the other Mac.")
            return
        }
        pair(payload: payload, manager: manager)
    }

    func pair(discovered: DiscoveredRemoteMac, code: String, manager: RemoteMacManager) {
        guard discovered.macID != RemoteMacIdentity.id else {
            state = .failed(Self.selfMessage)
            return
        }
        guard CompanionCrypto.isValidCode(code) else {
            state = .failed("Enter the 8-digit code shown on the other Mac.")
            return
        }
        run(
            name: discovered.name, endpoints: [discovered.endpoint], bootstrap: .code(code),
            hosts: [], port: Companion.defaultPort, expectedID: discovered.macID, manager: manager
        )
    }

    func pair(host: String, port: UInt16, code: String, manager: RemoteMacManager) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Enter the other Mac's address and port.")
            return
        }
        guard CompanionCrypto.isValidCode(code) else {
            state = .failed("Enter the 8-digit code shown on the other Mac.")
            return
        }
        run(
            name: trimmed, endpoints: [.hostPort(host: NWEndpoint.Host(trimmed), port: endpointPort)],
            bootstrap: .code(code), hosts: [trimmed], port: port, expectedID: nil, manager: manager
        )
    }

    func cancel() {
        task?.cancel()
        current?.cancel()
        task = nil
        current = nil
        state = .idle
    }

    func reject(_ text: String) {
        if !isWorking { state = .failed(text) }
    }

    func reset() {
        if !isWorking { state = .idle }
    }

    private func run(
        name: String, endpoints: [NWEndpoint], bootstrap: CompanionBootstrap, hosts: [String], port: UInt16,
        expectedID: UUID?, manager: RemoteMacManager
    ) {
        guard !endpoints.isEmpty else {
            state = .failed("No address to connect to.")
            return
        }
        state = .working("Pairing with \(name)")
        task = Task { [weak self] in
            var last = PairingFailure.unreachable
            attempts: for endpoint in endpoints {
                guard !Task.isCancelled, let self else { return }
                let attempt = PairingAttempt(endpoint: endpoint, bootstrap: bootstrap)
                current = attempt
                attempt.onCode = { [weak self] code in
                    self?.state = .checking(code: Self.grouped(code), macName: name)
                }
                switch await attempt.run() {
                case .success(let paired):
                    guard !Task.isCancelled else { return }
                    current = nil
                    if paired.macID == RemoteMacIdentity.id {
                        state = .failed(Self.selfMessage)
                        return
                    }
                    if let expectedID, expectedID != paired.macID {
                        state = .failed("That is not the Mac you chose.")
                        return
                    }
                    var storedHosts = hosts
                    var storedPort = port
                    if storedHosts.isEmpty, let host = paired.host, let resolvedPort = paired.port {
                        storedHosts = [host]
                        storedPort = resolvedPort
                    }
                    manager.addPaired(macID: paired.macID, name: paired.macName, key: paired.key, hosts: storedHosts, port: storedPort)
                    state = .done(paired.macName)
                    return
                case .failure(let failure):
                    last = failure
                    if case .rejected = failure { break attempts }
                }
            }
            guard let self, !Task.isCancelled else { return }
            current = nil
            state = .failed(Self.message(for: last))
        }
    }

    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    private static func message(for failure: PairingFailure) -> String {
        switch failure {
        case .rejected(let text):
            text
        case .unreachable, .timedOut:
            "Could not connect. Check the address, that Remote Access is on in Turm on the other Mac, and that the code is current and correct."
        }
    }
}
