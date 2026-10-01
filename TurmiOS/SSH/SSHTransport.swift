import Foundation
import Network

enum SSHTransport {
    // a Network.framework probe raises the Local Network prompt that BSD sockets never trigger, and reports a refusal clearly
    nonisolated static func preflight(host: String, port: Int) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw SSHTransportError(.posix(.EINVAL))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "app.turm.ssh.preflight")
        let outcome = Outcome()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                outcome.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        outcome.finish(nil)
                    case .failed(let error):
                        outcome.finish(SSHTransportError(error))
                    case .waiting(let error) where SSHTransportError.isPermanent(error):
                        outcome.finish(SSHTransportError(error))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 15) { outcome.finish(SSHTransportError(.posix(.ETIMEDOUT))) }
            }
        } onCancel: {
            outcome.finish(CancellationError())
        }
        connection.cancel()
    }
}

private nonisolated final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Void, Error>?

    func finish(_ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

struct SSHTransportError: LocalizedError {
    let underlying: NWError

    init(_ underlying: NWError) {
        self.underlying = underlying
    }

    static func isPermanent(_ error: NWError) -> Bool {
        switch error {
        case .posix(.EPERM), .posix(.EACCES), .posix(.ECONNREFUSED): true
        case .dns(let code): code == -65570
        default: false
        }
    }

    var errorDescription: String? {
        switch underlying {
        case .posix(.EPERM), .posix(.EACCES):
            "Turm is not allowed to reach this address. Allow Local Network for Turm in Settings > Privacy & Security > Local Network."
        case .dns(let code) where code == -65570:
            "Turm is not allowed to look up local hosts. Allow Local Network for Turm in Settings > Privacy & Security > Local Network."
        case .posix(.ECONNREFUSED):
            "The server refused the connection. Check the host and port."
        case .posix(.ETIMEDOUT):
            "The server did not answer in time."
        case .dns:
            "The host name could not be found."
        default:
            underlying.localizedDescription
        }
    }
}
