import Foundation
import Network
import Security

public nonisolated final class CompanionConnection: @unchecked Sendable {
    public nonisolated enum State: Sendable, Equatable {
        case preparing
        case waiting(String)
        case ready
        case closed
        case failed(String)
    }

    public static let maxQueuedBytes = 32 * 1024 * 1024

    @MainActor public var onMessage: ((CompanionMessage) -> Void)?
    @MainActor public var onState: ((State) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.turm.companion.connection")
    private var coder = CompanionFrameCoder()
    private var queuedBytes = 0
    private var started = false
    private var finished = false

    public init(endpoint: NWEndpoint, parameters: NWParameters) {
        connection = NWConnection(to: endpoint, using: parameters)
    }

    public convenience init?(host: String, port: UInt16, parameters: NWParameters) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port), parameters: parameters)
    }

    public init(accepted connection: NWConnection) {
        self.connection = connection
    }

    public var endpoint: NWEndpoint {
        connection.endpoint
    }

    public var remoteEndpoint: NWEndpoint? {
        queue.sync { connection.currentPath?.remoteEndpoint }
    }

    // set when the stream failed inside TLS rather than at TCP level
    public private(set) var tlsFailed = false

    public var negotiatedCipherSuite: UInt16? {
        queue.sync { () -> UInt16? in
            guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
            return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
        }
    }

    public func start() {
        queue.async { [self] in
            guard !started, !finished else { return }
            started = true
            connection.stateUpdateHandler = { [self] state in handle(state) }
            connection.start(queue: queue)
            receive()
        }
    }

    @discardableResult
    public func send(_ message: CompanionMessage) -> Bool {
        guard let frame = try? CompanionFrameCoder.encode(message) else { return false }
        queue.async { [self] in
            guard !finished else { return }
            queuedBytes += frame.count
            if queuedBytes > Self.maxQueuedBytes {
                finish(.failed("The peer is not keeping up."))
                return
            }
            connection.send(content: frame, completion: .contentProcessed { [self] error in
                queuedBytes -= frame.count
                if let error { finish(.failed(error.localizedDescription)) }
            })
        }
        return true
    }

    public func cancel() {
        queue.async { [self] in finish(.closed) }
    }

    public func close() {
        queue.async { [self] in
            guard !finished else { return }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                finish(.closed)
            })
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing: report(.preparing)
        case .waiting(let error): report(.waiting(error.localizedDescription))
        case .ready: report(.ready)
        case .failed(let error):
            noteTLS(error)
            finish(.failed(error.localizedDescription))
        case .cancelled: finish(.closed)
        @unknown default: break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            guard !finished else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try coder.feed(data)
                    if !messages.isEmpty { deliver(messages) }
                } catch {
                    finish(.failed("The peer sent invalid data."))
                    return
                }
            }
            if let error {
                noteTLS(error)
                finish(.failed(error.localizedDescription))
            } else if complete {
                finish(.closed)
            } else {
                receive()
            }
        }
    }

    private func noteTLS(_ error: NWError) {
        if case .tls = error { tlsFailed = true }
    }

    private func finish(_ state: State) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        report(state)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onState?(state) }
        }
    }

    private func deliver(_ messages: [CompanionMessage]) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                for message in messages { onMessage?(message) }
            }
        }
    }
}
