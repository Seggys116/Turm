import Darwin
import Foundation
import Network
import Observation
import TurmCore

final class CompanionPeer {
    enum Stage {
        case unauthenticated
        case pairing
        case authenticated
    }

    let id = UUID()
    let connection: CompanionConnection
    var stage = Stage.unauthenticated
    var deviceID: UUID?
    var name = ""
    var responder: CompanionPairingResponder?
    var wasReady = false
    var remote = ""
    var version: CompanionVersion?
    var attached: Set<UUID> = []
    var timeout: Task<Void, Never>?
    private let sink: ((CompanionMessage) -> Bool)?

    init(connection: CompanionConnection, sink: ((CompanionMessage) -> Bool)? = nil) {
        self.connection = connection
        self.sink = sink
    }

    @discardableResult
    func send(_ message: CompanionMessage) -> Bool {
        if let version, !version.supports(message.kind) { return false }
        return sink?(message) ?? connection.send(message)
    }
}

enum CompanionAddresses {
    struct Entry: Equatable {
        let interface: String
        let address: String

        var isTailscale: Bool { CompanionAddresses.isTailscale(address) }
    }

    // 100.64.0.0/10, the carrier-grade NAT range Tailscale assigns from
    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func local() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [Entry] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)
            let name = String(cString: item.ifa_name)
            guard !text.hasPrefix("169.254."), name.hasPrefix("en") || isTailscale(text) else { continue }
            found.append(Entry(interface: name, address: text))
        }
        return found
    }

    static var hostname: String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") || name.contains(".") ? name : name + ".local"
    }

    static func shareable() -> [String] {
        let entries = local()
        return entries.filter { !$0.isTailscale }.map(\.address) + entries.filter(\.isTailscale).map(\.address) + [hostname]
    }
}

@Observable
final class CompanionServer {
    static let shared = CompanionServer()
    static let enabledKey = "turm.companion.enabled"
    static let portKey = "turm.companion.port"
    static let macIDKey = "turm.companion.macID"
    static let pairingLifetime: TimeInterval = 120
    static let maxFailures = 3
    private static let maxPeers = 16
    private static let maxHandshaking = 32
    private static let maxPerHost = 4
    private static let helloDeadline: Duration = .seconds(10)
    private static let approvalDeadline: Duration = .seconds(60)

    enum Status: Equatable {
        case off
        case starting
        case listening(UInt16)
        case failed(String)
    }

    enum PairingOutcome: Equatable {
        case paired(String)
        case expired
        case tooManyAttempts
    }

    struct UpdateNotice: Equatable {
        let text: String
        let macIsOutdated: Bool
    }

    struct PendingApproval: Equatable {
        let deviceName: String
        let code: String
    }

    struct PairingWindow: Equatable {
        var payload: PairingPayload
        let code: String
        var failures = 0
        var inUse = false
        var pending: PendingApproval?

        var isOpen: Bool {
            !payload.isExpired() && failures < CompanionServer.maxFailures && !inUse
        }
    }

    private(set) var status = Status.off
    private(set) var pairing: PairingWindow?
    private(set) var outcome: PairingOutcome?
    private(set) var liveDevices: Set<UUID> = []
    private(set) var updateNotices: [UUID: UpdateNotice] = [:]

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: CompanionPeer] = [:]
    @ObservationIgnored private var pairingPeer: UUID?
    @ObservationIgnored private var pairingTimer: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var strikes: [String: [Date]] = [:]
    @ObservationIgnored private var blockedUntil: [String: Date] = [:]
    @ObservationIgnored private let bridge = CompanionBridge()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var announced: CompanionMessage?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1...Int(UInt16.max)).contains(stored) ? UInt16(stored) : Companion.defaultPort
    }

    var macID: UUID {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: Self.macIDKey), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.macIDKey)
        return id
    }

    @ObservationIgnored var localVersion = CompanionVersion.current
    @ObservationIgnored var devices = PairedDevices.shared

    var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        retries = 0
        rebuildListener()
        watchNetwork()
    }

    func settingsChanged() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        endPairing(outcome: nil)
        retryTask?.cancel()
        listener?.cancel()
        listener = nil
        for peer in Array(peers.values) { drop(peer) }
        status = .off
    }

    func devicesChanged() {
        if listener != nil { rebuildListener() }
    }

    func deviceRevoked(_ id: UUID) {
        updateNotices[id] = nil
        for peer in Array(peers.values) where peer.deviceID == id { drop(peer) }
        devicesChanged()
    }

    @discardableResult
    func beginPairing() -> Bool {
        guard isEnabled, listener != nil else { return false }
        let payload = PairingPayload(
            macID: macID, macName: macName, hosts: CompanionAddresses.shareable(), port: port,
            secret: CompanionCrypto.generateSecret(), expires: Date().addingTimeInterval(Self.pairingLifetime)
        )
        pairingTimer?.cancel()
        outcome = nil
        pairing = PairingWindow(payload: payload, code: CompanionCrypto.generateCode())
        pairingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            while !Task.isCancelled, let self, self.pairing?.payload.secret == payload.secret {
                guard self.pairing?.inUse == true else {
                    self.endPairing(outcome: .expired)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        rebuildListener()
        return true
    }

    func endPairing(outcome result: PairingOutcome? = nil) {
        pairingTimer?.cancel()
        pairingTimer = nil
        pairingPeer = nil
        guard pairing != nil else { return }
        pairing = nil
        outcome = result
        if listener != nil { rebuildListener() }
    }

    private func rebuildListener() {
        listener?.cancel()
        listener = nil
        retryTask?.cancel()
        guard let port = NWEndpoint.Port(rawValue: self.port) else {
            status = .failed("The port must be between 1 and 65535.")
            return
        }
        var credentials = devices.credentials
        if let pairing {
            credentials.append(CompanionTLS.Credential(identity: CompanionBootstrap.qrIdentity, key: CompanionBootstrap.qr(secret: pairing.payload.secret).key))
            credentials.append(CompanionTLS.Credential(identity: CompanionBootstrap.codeIdentity, key: CompanionBootstrap.code(pairing.code).key))
        }
        do {
            let created = try NWListener(using: CompanionTLS.serverParameters(credentials: credentials), on: port)
            let record = NWTXTRecord(["id": macID.uuidString])
            created.service = NWListener.Service(name: macName, type: Companion.serviceType, txtRecord: record)
            created.stateUpdateHandler = { [weak self, weak created] state in
                MainActor.assumeIsolated {
                    guard let self, let created else { return }
                    self.listenerChanged(state, listener: created)
                }
            }
            created.newConnectionHandler = { [weak self, weak created] connection in
                MainActor.assumeIsolated {
                    guard let self, let created, created === self.listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener = created
            if status == .off { status = .starting }
            created.start(queue: .main)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func listenerChanged(_ state: NWListener.State, listener changed: NWListener) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            retries = 0
            status = .listening(port)
            announceAddresses()
        case .failed(let error):
            listener?.cancel()
            listener = nil
            status = .failed(describe(error))
            scheduleRetry()
        case .waiting(let error):
            status = .failed(describe(error))
        default:
            break
        }
    }

    var addresses: CompanionMessage {
        .addresses(hosts: CompanionAddresses.shareable(), port: port)
    }

    // phones keep reaching this Mac after its IP changes, over whichever path still works
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.announceAddresses() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func announceAddresses() {
        let message = addresses
        guard message != announced else { return }
        announced = message
        for peer in peers.values where peer.stage == .authenticated { peer.send(message) }
    }

    private func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error {
            return "Port \(port) is in use, probably by another copy of Turm. Quit it or choose another port."
        }
        return error.localizedDescription
    }

    private func scheduleRetry() {
        guard retries < 3, isEnabled else { return }
        retries += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.rebuildListener()
        }
    }

    private func accept(_ network: NWConnection) {
        let remote = Self.host(of: network.endpoint)
        let now = Date()
        blockedUntil = blockedUntil.filter { $0.value > now }
        strikes = strikes.filter { $0.value.contains { now.timeIntervalSince($0) < 30 } }
        let handshaking = peers.values.filter { !$0.wasReady }.count
        let sameHost = peers.values.filter { $0.remote == remote && $0.stage != .authenticated }.count
        let authenticated = peers.values.filter { $0.stage == .authenticated }.count
        guard blockedUntil[remote] == nil, sameHost < Self.maxPerHost, handshaking < Self.maxHandshaking, authenticated < Self.maxPeers else {
            network.cancel()
            return
        }
        let peer = CompanionPeer(connection: CompanionConnection(accepted: network))
        peer.remote = remote
        peers[peer.id] = peer
        peer.connection.onState = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            self.stateChanged(state, of: peer)
        }
        peer.connection.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peers[peer.id] != nil else { return }
            self.received(message, from: peer)
        }
        peer.timeout = Task { [weak self, weak peer] in
            try? await Task.sleep(for: Self.helloDeadline)
            guard !Task.isCancelled, let self, let peer, peer.stage != .authenticated else { return }
            self.drop(peer)
        }
        peer.connection.start()
    }

    private func stateChanged(_ state: CompanionConnection.State, of peer: CompanionPeer) {
        switch state {
        case .ready:
            peer.wasReady = true
        case .failed, .closed:
            guard peers[peer.id] != nil else { return }
            let handshakeFailed = !peer.wasReady
            let insideTLS = peer.connection.tlsFailed
            drop(peer)
            guard handshakeFailed else { return }
            strike(peer.remote)
            if insideTLS { registerPairingFailure() }
        case .preparing, .waiting:
            break
        }
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unknown" }
        return "\(host)".split(separator: "%").first.map(String.init) ?? "unknown"
    }

    private func strike(_ remote: String) {
        let now = Date()
        var recent = (strikes[remote] ?? []).filter { now.timeIntervalSince($0) < 30 }
        recent.append(now)
        strikes[remote] = recent
        guard recent.count >= 5 else { return }
        strikes[remote] = nil
        blockedUntil[remote] = now.addingTimeInterval(30)
    }

    private func registerPairingFailure() {
        guard var window = pairing, !window.inUse else { return }
        window.failures += 1
        pairing = window
        if window.failures >= Self.maxFailures { endPairing(outcome: .tooManyAttempts) }
    }

    func drop(_ peer: CompanionPeer) {
        peer.timeout?.cancel()
        peers[peer.id] = nil
        if pairingPeer == peer.id {
            pairingPeer = nil
            if var window = pairing {
                window.inUse = false
                window.pending = nil
                pairing = window
            }
        }
        bridge.peerClosed(peer)
        peer.connection.cancel()
        refreshLiveDevices()
    }

    private func refreshLiveDevices() {
        let live = Set(peers.values.compactMap { $0.stage == .authenticated ? $0.deviceID : nil })
        if live != liveDevices { liveDevices = live }
    }

    private func reject(_ peer: CompanionPeer, code: String, text: String) {
        reject(peer, with: .error(code: code, text: text))
    }

    private func reject(_ peer: CompanionPeer, with message: CompanionMessage) {
        peer.send(message)
        peer.connection.close()
        peer.timeout?.cancel()
        peers[peer.id] = nil
        bridge.peerClosed(peer)
        refreshLiveDevices()
    }

    func received(_ message: CompanionMessage, from peer: CompanionPeer) {
        switch peer.stage {
        case .unauthenticated:
            switch message {
            case .hello(let version, let deviceID, let name, let proof):
                authenticate(peer, version: version, deviceID: deviceID, name: name, proof: proof)
            case .pairBegin:
                beginPairing(with: peer, message)
            default:
                reject(peer, code: CompanionErrorCode.unauthorized, text: "Say hello first.")
            }
        case .pairing:
            continuePairing(with: peer, message)
        case .authenticated:
            if case .ping = message {
                peer.send(.pong)
            } else {
                bridge.handle(message, from: peer)
            }
        }
    }

    private func authenticate(_ peer: CompanionPeer, version: CompanionVersion, deviceID: UUID, name: String, proof: Data) {
        let (reply, compatibility) = CompanionHandshake.answer(hello: version, local: localVersion, macName: macName)
        let device = devices.device(deviceID).flatMap {
            CompanionCrypto.verifyHelloProof(proof, key: $0.key, deviceID: deviceID) ? $0 : nil
        }
        if let device {
            let advice = compatibility.advice(local: localVersion, remote: version, here: "this Mac", there: device.name)
            updateNotices[deviceID] = advice.map { UpdateNotice(text: $0, macIsOutdated: compatibility.outdated == .local) }
        }
        guard compatibility.isCompatible else {
            reject(peer, with: reply)
            return
        }
        guard let device else {
            strike(peer.remote)
            reject(peer, code: CompanionErrorCode.unauthorized, text: "This device is not paired.")
            return
        }
        peer.timeout?.cancel()
        peer.stage = .authenticated
        peer.deviceID = deviceID
        peer.name = device.name
        peer.send(reply)
        peer.version = version
        peer.send(addresses)
        refreshLiveDevices()
        bridge.peerAuthenticated(peer)
    }

    private func beginPairing(with peer: CompanionPeer, _ message: CompanionMessage) {
        guard var window = pairing, window.isOpen else {
            reject(peer, code: CompanionErrorCode.busy, text: "Pairing is not open on this Mac.")
            return
        }
        window.inUse = true
        pairing = window
        pairingPeer = peer.id
        peer.stage = .pairing
        var responder = CompanionPairingResponder(
            candidates: [.qr(secret: window.payload.secret), .code(window.code)], macID: macID, macName: macName
        )
        let step = responder.receive(message)
        peer.responder = responder
        if case .send(let reply) = step {
            peer.send(reply)
        } else {
            failPairing(peer, text: "Pairing could not start.")
        }
    }

    private func continuePairing(with peer: CompanionPeer, _ message: CompanionMessage) {
        guard var responder = peer.responder, let window = pairing, !window.payload.isExpired() else {
            failPairing(peer, text: "Pairing expired.")
            return
        }
        let step = responder.receive(message)
        peer.responder = responder
        apply(step, to: peer)
    }

    private func apply(_ step: CompanionPairingResponder.Step, to peer: CompanionPeer) {
        switch step {
        case .send(let reply):
            peer.send(reply)
        case .rejected(let text):
            failPairing(peer, text: text)
        case .approval(_, let deviceID, _) where deviceID == macID:
            failPairing(peer, text: "A Mac cannot pair with itself.")
        case .finished(let deviceID, _, _, _) where deviceID == macID:
            failPairing(peer, text: "A Mac cannot pair with itself.")
        case .approval(let code, _, let name):
            peer.timeout?.cancel()
            pairing?.pending = PendingApproval(deviceName: PairedDevices.clean(name), code: code)
            peer.timeout = Task { [weak self, weak peer] in
                try? await Task.sleep(for: Self.approvalDeadline)
                guard !Task.isCancelled, let self, let peer, self.peers[peer.id] != nil else { return }
                self.failPairing(peer, text: "The pairing was not approved in time.")
            }
        case .finished(let deviceID, let name, let key, let reply):
            do {
                try devices.add(id: deviceID, name: name, key: key)
            } catch {
                failPairing(peer, text: "The pairing key could not be stored.")
                return
            }
            peer.send(reply)
            peer.connection.close()
            peer.timeout?.cancel()
            peers[peer.id] = nil
            let stored = devices.device(deviceID)?.name ?? name
            endPairing(outcome: .paired(stored))
        }
    }

    func approvePairing() {
        guard pairing?.pending != nil, let id = pairingPeer, let peer = peers[id], var responder = peer.responder else { return }
        let step = responder.approve()
        peer.responder = responder
        apply(step, to: peer)
    }

    func rejectPairing() {
        guard pairing?.pending != nil, let id = pairingPeer, let peer = peers[id] else { return }
        failPairing(peer, text: "The pairing was declined on the Mac.")
    }

    private func failPairing(_ peer: CompanionPeer, text: String) {
        peer.send(.error(code: CompanionErrorCode.unauthorized, text: text))
        peer.connection.close()
        peer.timeout?.cancel()
        peers[peer.id] = nil
        pairingPeer = nil
        guard var window = pairing else { return }
        window.inUse = false
        window.pending = nil
        window.failures += 1
        pairing = window
        if window.failures >= Self.maxFailures { endPairing(outcome: .tooManyAttempts) }
    }
}
