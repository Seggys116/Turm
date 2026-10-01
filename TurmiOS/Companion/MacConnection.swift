import Foundation
import Network
import Observation
import TurmCore

struct MacRequestError: Error {
    let text: String
}

@Observable
final class MacConnection: Identifiable {
    enum State: Equatable {
        case offline
        case connecting
        case connected
        case retrying(String)
        case failed(String)
    }

    struct CloseRequest: Identifiable {
        let id: UUID
        let message: String
    }

    private static let handshakeDeadline: Duration = .seconds(10)
    private static let heartbeatInterval: Duration = .seconds(15)
    private static let silenceLimit: TimeInterval = 50

    private(set) var record: CompanionPeerRecord
    private(set) var state = State.offline
    private(set) var sessions: [SessionSummary] = []
    private(set) var notice: String?
    private(set) var remoteVersion: CompanionVersion?
    private(set) var updateAdvice: String?
    var closeRequest: CloseRequest?
    var discovered: NWEndpoint?

    @ObservationIgnored private let keychain: CompanionKeychain
    @ObservationIgnored private var connection: CompanionConnection?
    @ObservationIgnored private var connectedHost: String?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lastReceived = Date()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var shells: [UUID: MacShell] = [:]
    @ObservationIgnored private var awaitingShell: (known: Set<UUID>, created: (UUID) -> Void)?
    @ObservationIgnored private var awaitingTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: PendingRequest] = [:]
    @ObservationIgnored private var requestCounter = 0
    private(set) var shortcuts: [Shortcut] = []

    private struct PendingRequest {
        let token: Int
        let resolve: (CompanionMessage) -> Void
    }

    init(record: CompanionPeerRecord, keychain: CompanionKeychain) {
        self.record = record
        self.keychain = keychain
    }

    var id: UUID { record.id }
    var name: String { record.name }

    func start() {
        wanted = true
        guard !suspended, connection == nil else { return }
        open()
    }

    func stop() {
        wanted = false
        teardown()
        state = .offline
    }

    func suspend() {
        suspended = true
        teardown()
        if wanted { state = .offline }
    }

    func resume() {
        suspended = false
        attempt = 0
        if wanted, connection == nil { open() }
    }

    func endpointsChanged() {
        guard wanted, !suspended, state != .connected, state != .connecting else { return }
        teardown()
        attempt = 0
        open()
    }

    func updateAddresses(hosts: [String], port: UInt16) {
        record.hosts = hosts
        record.port = port
        try? keychain.save(record)
        if wanted, !suspended, state != .connected {
            teardown()
            attempt = 0
            open()
        }
    }

    // the first session for a shell attaches it on the Mac
    func session(for id: UUID) -> MacSession {
        let shell: MacShell
        if let existing = shells[id] {
            shell = existing
        } else {
            shell = MacShell(id: id)
            shells[id] = shell
            if state == .connected { send(.attach(id: id)) }
        }
        return MacSession(connection: self, shell: shell)
    }

    func release(_ shell: MacShell) {
        guard shells[shell.id] === shell, shell.isUnused else { return }
        shells[shell.id] = nil
        if state == .connected, !shell.hasEnded { send(.detach(id: shell.id)) }
    }

    func send(_ message: CompanionMessage) {
        guard supports(message.kind) else { return }
        #if targetEnvironment(simulator)
        if connection == nil, let demo = DemoMac.shared {
            demo.answer(message)
            return
        }
        #endif
        connection?.send(message)
    }

    func supports(_ kind: CompanionMessage.Kind) -> Bool {
        remoteVersion?.supports(kind) ?? true
    }

    func closeSession(_ id: UUID, force: Bool) {
        send(.close(id: id, force: force))
    }

    func createShell(directory: String?, created: @escaping (UUID) -> Void) {
        let trimmed = directory?.trimmingCharacters(in: .whitespaces)
        awaitingShell = (Set(sessions.map(\.id)), created)
        awaitingTask?.cancel()
        awaitingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.awaitingShell = nil
        }
        send(.create(directory: trimmed?.isEmpty == false ? trimmed : nil, command: nil))
    }

    private func claimNewShell() {
        guard let awaiting = awaitingShell, let new = sessions.first(where: { !awaiting.known.contains($0.id) }) else { return }
        awaitingShell = nil
        awaitingTask?.cancel()
        awaiting.created(new.id)
    }

    func summary(of id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    func refreshSessions() {
        send(.listSessions)
    }

    private func endpoints() -> [NWEndpoint] {
        var list: [NWEndpoint] = []
        if let discovered { list.append(discovered) }
        let port = NWEndpoint.Port(rawValue: record.port == 0 ? Companion.defaultPort : record.port)
        if let port {
            list += record.hosts.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: port) }
        }
        return list
    }

    private func open() {
        let candidates = endpoints()
        guard !candidates.isEmpty else {
            state = .failed("No address is known for this Mac. Add one in its details.")
            return
        }
        state = .connecting
        authenticated = false
        let target = candidates[attempt % candidates.count]
        if case .hostPort(let host, _) = target { connectedHost = "\(host)" } else { connectedHost = nil }
        let created = CompanionConnection(
            endpoint: target,
            parameters: CompanionTLS.clientParameters(identity: CompanionDevice.id.uuidString, key: record.key)
        )
        connection = created
        created.onState = { [weak self, weak created] state in
            guard let self, let created, created === connection else { return }
            handle(state)
        }
        created.onMessage = { [weak self, weak created] message in
            guard let self, let created, created === connection else { return }
            lastReceived = Date()
            handle(message)
        }
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self, weak created] in
            try? await Task.sleep(for: Self.handshakeDeadline)
            guard !Task.isCancelled, let self, let created, created === connection, !authenticated else { return }
            connectionEnded("The Mac did not answer.")
        }
        created.start()
    }

    private func teardown() {
        retryTask?.cancel()
        handshakeTask?.cancel()
        heartbeatTask?.cancel()
        retryTask = nil
        handshakeTask = nil
        heartbeatTask = nil
        let held = connection
        connection = nil
        authenticated = false
        held?.cancel()
    }

    private func handle(_ state: CompanionConnection.State) {
        switch state {
        case .ready:
            let proof = CompanionCrypto.helloProof(key: record.key, deviceID: CompanionDevice.id)
            remoteVersion = nil
            send(.hello(version: .current, deviceID: CompanionDevice.id, name: CompanionDevice.name, proof: proof))
        case .failed(let reason):
            connectionEnded(authenticated ? reason : "Could not reach the Mac.")
        case .closed:
            connectionEnded("The connection was closed.")
        case .preparing, .waiting:
            break
        }
    }

    private func connectionEnded(_ reason: String) {
        teardown()
        guard wanted, !suspended else {
            state = .offline
            return
        }
        let delay = min(30, 1 << min(attempt, 5))
        attempt += 1
        state = .retrying(reason)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, wanted, !suspended, connection == nil else { return }
            open()
        }
    }

    private func fail(_ text: String) {
        wanted = false
        teardown()
        state = .failed(text)
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .welcome(_, let macName):
            guard let handshake = CompanionHandshake.read(message) else { return }
            let advice = handshake.compatibility.advice(
                local: .current, remote: handshake.remote, here: "this device", there: macName.isEmpty ? name : macName
            )
            guard handshake.compatibility.isCompatible else {
                fail(advice ?? "This Mac cannot talk to this version of Turm.")
                return
            }
            remoteVersion = handshake.remote
            updateAdvice = advice
            handshakeTask?.cancel()
            authenticated = true
            attempt = 0
            state = .connected
            if !macName.isEmpty, macName != record.name {
                record.name = macName
                try? keychain.save(record)
            }
            send(.listSessions)
            send(.listShortcuts)
            for (id, shell) in shells {
                if shell.isUnused {
                    shells[id] = nil
                } else if !shell.hasEnded {
                    send(.attach(id: id))
                }
            }
            startHeartbeat()
        case .incompatible:
            guard let handshake = CompanionHandshake.read(message) else { return }
            updateAdvice = handshake.compatibility.advice(local: .current, remote: handshake.remote, here: "this device", there: name)
            fail(updateAdvice ?? "This Mac cannot talk to this version of Turm.")
        case .addresses(let hosts, let port):
            var updated = record
            guard updated.learn(hosts: hosts, port: port, via: connectedHost) else { return }
            record = updated
            try? keychain.save(record)
        case .pong:
            break
        case .sessions(let list):
            sessions = list
            claimNewShell()
        case .sessionChanged(let summary):
            if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
                sessions[index] = summary
            } else {
                sessions.append(summary)
            }
            claimNewShell()
        case .sessionClosed(let id):
            sessions.removeAll { $0.id == id }
            shells[id]?.ended()
        case .snapshot(let id, _, _, _, _), .blockStarted(let id, _, _, _, _, _, _), .output(let id, _, _),
             .blockFinished(let id, _, _), .phase(let id, _, _):
            shells[id]?.handle(message)
        case .confirmClose(let id, let text):
            closeRequest = CloseRequest(id: id, message: text)
        case .shortcuts(let list):
            shortcuts = list
        case .directoryShortcutInfo(let path, _, _):
            complete("directory:" + path, with: message)
        case .commandShortcutInfo(let command, _, _):
            complete("command:" + command, with: message)
        case .branches(let id, _, _):
            complete("branches:\(id)", with: message)
        case .branchSwitched(let id, _, _):
            complete("switch:\(id)", with: message)
        case .ok(let request):
            complete(request, with: message)
        case .error(let code, let text):
            handleError(code: code, text: text)
        default:
            break
        }
    }

    private func complete(_ key: String, with message: CompanionMessage) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.resolve(message)
    }

    private func perform(_ message: CompanionMessage, key: String) async throws -> CompanionMessage {
        guard state == .connected else { throw MacRequestError(text: "Not connected to \(name).") }
        guard supports(message.kind) else { throw MacRequestError(text: "Update Turm on \(name) to use this.") }
        requestCounter += 1
        let token = requestCounter
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<CompanionMessage, Never>) in
            pending[key]?.resolve(.error(code: CompanionErrorCode.busy, text: "Superseded by a newer request."))
            pending[key] = PendingRequest(token: token) { continuation.resume(returning: $0) }
            send(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, pending[key]?.token == token else { return }
                complete(key, with: .error(code: CompanionErrorCode.failed, text: "The Mac did not answer."))
            }
        }
        if case .error(_, let text) = reply { throw MacRequestError(text: text) }
        return reply
    }

    func directoryShortcut(path: String) async throws -> (existing: Shortcut?, draft: Shortcut) {
        let reply = try await perform(.directoryShortcut(path: path), key: "directory:" + path)
        guard case .directoryShortcutInfo(_, let existing, let draft) = reply else { throw MacRequestError(text: "Unexpected reply.") }
        return (existing, draft)
    }

    func commandShortcut(command: String) async throws -> (existing: Shortcut?, draft: Shortcut) {
        let reply = try await perform(.commandShortcut(command: command), key: "command:" + command)
        guard case .commandShortcutInfo(_, let existing, let draft) = reply else { throw MacRequestError(text: "Unexpected reply.") }
        return (existing, draft)
    }

    func saveShortcut(_ shortcut: Shortcut) async throws {
        _ = try await perform(.saveShortcut(shortcut), key: "saveShortcut")
    }

    func removeShortcut(_ id: UUID) async throws {
        _ = try await perform(.removeShortcut(id: id), key: "removeShortcut")
    }

    func revealInFinder(path: String) async throws {
        _ = try await perform(.revealInFinder(path: path), key: "revealInFinder")
    }

    func branches(of id: UUID) async throws -> (names: [String], current: String?) {
        let reply = try await perform(.listBranches(id: id), key: "branches:\(id)")
        guard case .branches(_, let names, let current) = reply else { throw MacRequestError(text: "Unexpected reply.") }
        return (names, current)
    }

    func switchBranch(of id: UUID, to name: String) async throws -> String? {
        let reply = try await perform(.switchBranch(id: id, name: name), key: "switch:\(id)")
        guard case .branchSwitched(_, _, let failure) = reply else { throw MacRequestError(text: "Unexpected reply.") }
        return failure
    }

    func report(_ text: String) {
        showNotice(text)
    }

    private func handleError(code: String, text: String) {
        switch code {
        case CompanionErrorCode.unauthorized where !authenticated:
            fail("This Mac no longer recognises this device. Forget it and pair again.")
        case _ where !pending.isEmpty:
            let waiting = pending
            pending = [:]
            for request in waiting.values { request.resolve(.error(code: code, text: text)) }
        default:
            awaitingShell = nil
            showNotice(text)
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        lastReceived = Date()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(lastReceived) > Self.silenceLimit {
                    connectionEnded("The Mac stopped responding.")
                    return
                }
                send(.ping)
            }
        }
    }
}

#if targetEnvironment(simulator)
extension MacConnection {
    func showDemo(shells list: [DemoShell]) {
        DemoMac.shared = DemoMac(shells: list) { [weak self] message in self?.handle(message) }
        state = .connected
        sessions = list.map(\.summary)
    }

    func deliverDemo(_ message: CompanionMessage) {
        handle(message)
    }
}
#endif
