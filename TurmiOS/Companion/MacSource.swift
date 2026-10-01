import Foundation
import Network
import Observation
import TurmCore
import UIKit

struct MacEntry: Identifiable, Equatable, Sendable {
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

protocol MacSource: AnyObject {
    var macs: [MacEntry] { get }
    var selectedID: String? { get set }
}

struct DiscoveredMac: Identifiable, Equatable {
    let id: String
    let name: String
    let macID: UUID?
    let endpoint: NWEndpoint
}

@Observable
final class MacManager: MacSource {
    static let shared = MacManager()

    private(set) var connections: [MacConnection]
    private(set) var discovered: [DiscoveredMac] = []
    var selectedID: String?

    @ObservationIgnored private let keychain: CompanionKeychain
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browserRetry: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init(keychain: CompanionKeychain = CompanionKeychain(role: .phone)) {
        self.keychain = keychain
        connections = keychain.all().map { MacConnection(record: $0, keychain: keychain) }
    }

    var macs: [MacEntry] {
        let paired = connections.map { connection in
            MacEntry(
                id: connection.id.uuidString, name: connection.name, detail: Self.detail(of: connection),
                status: Self.status(of: connection)
            )
        }
        let pairedIDs = Set(connections.map(\.id))
        let nearby = discovered.filter { $0.macID.map { !pairedIDs.contains($0) } ?? true }.map {
            MacEntry(id: "nearby." + $0.id, name: $0.name, detail: "Nearby, not paired", status: .discovered, isPaired: false)
        }
        return paired + nearby
    }

    func connection(for id: String) -> MacConnection? {
        connections.first { $0.id.uuidString == id }
    }

    func start() {
        guard !started else { return }
        started = true
        startBrowsing()
        connections.forEach { $0.start() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startBrowsing()
                self.connections.forEach { $0.resume() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopBrowsing()
                self.connections.forEach { $0.suspend() }
            }
        })
    }

    func addPaired(macID: UUID, name: String, key: Data, hosts: [String], port: UInt16) {
        if let existing = connections.first(where: { $0.id == macID }) {
            existing.stop()
            connections.removeAll { $0.id == macID }
        }
        let record = CompanionPeerRecord(id: macID, name: name, key: key, hosts: hosts, port: port)
        try? keychain.save(record)
        let connection = MacConnection(record: record, keychain: keychain)
        connection.discovered = discovered.first { $0.macID == macID }?.endpoint
        connections.append(connection)
        connection.start()
    }

    func forget(_ id: UUID) {
        connections.first { $0.id == id }?.stop()
        keychain.remove(id)
        connections.removeAll { $0.id == id }
        if selectedID == id.uuidString { selectedID = nil }
    }

    private static func status(of connection: MacConnection) -> MacEntry.Status {
        switch connection.state {
        case .connected: .connected
        case .offline, .connecting: .paired
        case .retrying, .failed: .unreachable
        }
    }

    private static func detail(of connection: MacConnection) -> String {
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

    private nonisolated static func discovered(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var macID: UUID?
        if case .bonjour(let record) = result.metadata {
            macID = record["id"].flatMap { UUID(uuidString: $0) }
        }
        return DiscoveredMac(id: name, name: name, macID: macID, endpoint: result.endpoint)
    }

    private func apply(_ found: [DiscoveredMac]) {
        discovered = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for connection in connections {
            let endpoint = found.first { $0.macID == connection.id }?.endpoint
            guard endpoint != connection.discovered else { continue }
            connection.discovered = endpoint
            connection.endpointsChanged()
        }
    }
}

#if targetEnvironment(simulator)
extension MacManager {
    // stands in for the paired Macs for this launch only: nothing reaches the keychain and discovery never starts
    func showDemo(name: String, hosts: [String], shells: [DemoShell]) -> MacConnection {
        let record = CompanionPeerRecord(id: UUID(), name: name, key: Data(count: 32), hosts: hosts, port: Companion.defaultPort)
        let connection = MacConnection(record: record, keychain: keychain)
        connection.showDemo(shells: shells)
        connections = [connection]
        started = true
        return connection
    }
}
#endif
