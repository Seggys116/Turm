import AppKit
import Foundation
import Network
import Observation
import TurmCore

struct RemoteMacEntry: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case discovered
        case paired
        case connected
        case unreachable
    }

    let id: String
    var name: String
    var detail: String
    var status: Status
    var isPaired = true
}

struct DiscoveredRemoteMac: Identifiable, Equatable {
    let id: String
    let name: String
    let macID: UUID?
    let endpoint: NWEndpoint
}

@Observable
final class RemoteMacManager {
    static let shared = RemoteMacManager()

    private(set) var connections: [RemoteMacConnection]
    private(set) var discovered: [DiscoveredRemoteMac] = []
    var selectedID: String?

    @ObservationIgnored private let keychain: CompanionKeychain
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browserRetry: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var discoveryRequests = 0

    init(keychain: CompanionKeychain = CompanionKeychain(role: .phone)) {
        self.keychain = keychain
        connections = keychain.all().map { RemoteMacConnection(record: $0, keychain: keychain) }
    }

    var macs: [RemoteMacEntry] {
        let paired = connections.map { connection in
            RemoteMacEntry(
                id: connection.id.uuidString, name: connection.name, detail: Self.detail(of: connection),
                status: Self.status(of: connection)
            )
        }
        let pairedIDs = Set(connections.map(\.id))
        let nearby = discovered.filter { $0.macID.map { !pairedIDs.contains($0) } ?? true }.map {
            RemoteMacEntry(id: "nearby." + $0.id, name: $0.name, detail: "Nearby, not paired", status: .discovered, isPaired: false)
        }
        return paired + nearby
    }

    func connection(for id: String) -> RemoteMacConnection? {
        connections.first { $0.id.uuidString == id }
    }

    func start() {
        guard !started else { return }
        started = true
        updateBrowsing()
        connections.forEach { $0.start() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                self.updateBrowsing()
                self.connections.forEach { $0.resume() }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                self.updateBrowsing()
                self.connections.forEach { $0.suspend() }
            }
        })
    }

    func beginDiscovery() {
        discoveryRequests += 1
        updateBrowsing()
    }

    func endDiscovery() {
        discoveryRequests = max(0, discoveryRequests - 1)
        updateBrowsing()
    }

    // browsing is what triggers the Local Network prompt, so it runs only when something needs it
    private func updateBrowsing() {
        if started, !sleeping, !connections.isEmpty || discoveryRequests > 0 {
            startBrowsing()
        } else {
            stopBrowsing()
        }
    }

    func addPaired(macID: UUID, name: String, key: Data, hosts: [String], port: UInt16) {
        guard macID != RemoteMacIdentity.id else { return }
        if let existing = connections.first(where: { $0.id == macID }) {
            existing.stop()
            connections.removeAll { $0.id == macID }
        }
        let record = CompanionPeerRecord(id: macID, name: name, key: key, hosts: hosts, port: port)
        try? keychain.save(record)
        let connection = RemoteMacConnection(record: record, keychain: keychain)
        connection.discovered = discovered.first { $0.macID == macID }?.endpoint
        connections.append(connection)
        connection.start()
        updateBrowsing()
    }

    func forget(_ id: UUID) {
        connections.first { $0.id == id }?.stop()
        keychain.remove(id)
        connections.removeAll { $0.id == id }
        if selectedID == id.uuidString { selectedID = nil }
        updateBrowsing()
    }

    private static func status(of connection: RemoteMacConnection) -> RemoteMacEntry.Status {
        switch connection.state {
        case .connected: .connected
        case .offline, .connecting: .paired
        case .retrying, .failed: .unreachable
        }
    }

    private static func detail(of connection: RemoteMacConnection) -> String {
        switch connection.state {
        case .connected:
            let count = connection.sessions.count
            return count == 1 ? "1 session" : "\(count) sessions"
        case .connecting: return "Connecting"
        case .offline: return "Not connected"
        case .retrying(let reason), .failed(let reason): return reason
        }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let created = NWBrowser(for: .bonjourWithTXTRecord(type: Companion.serviceType, domain: nil), using: .tcp)
        created.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.discovered(from:))
            MainActor.assumeIsolated { self?.apply(found) }
        }
        created.stateUpdateHandler = { [weak self, weak created] state in
            MainActor.assumeIsolated {
                guard let self, let created, created === self.browser else { return }
                if case .failed = state { self.restartBrowsing() }
            }
        }
        browser = created
        created.start(queue: .main)
    }

    private func stopBrowsing() {
        browserRetry?.cancel()
        browser?.cancel()
        browser = nil
        discovered = []
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        browserRetry?.cancel()
        browserRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.startBrowsing()
        }
    }

    private nonisolated static func discovered(from result: NWBrowser.Result) -> DiscoveredRemoteMac? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var macID: UUID?
        if case .bonjour(let record) = result.metadata {
            macID = record["id"].flatMap { UUID(uuidString: $0) }
        }
        return DiscoveredRemoteMac(id: name, name: name, macID: macID, endpoint: result.endpoint)
    }

    private func apply(_ results: [DiscoveredRemoteMac]) {
        let own = RemoteMacIdentity.id
        let found = results.filter { $0.macID != own }
        discovered = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for connection in connections {
            let endpoint = found.first { $0.macID == connection.id }?.endpoint
            guard endpoint != connection.discovered else { continue }
            connection.discovered = endpoint
            connection.endpointsChanged()
        }
    }
}
