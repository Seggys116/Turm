import Citadel
import Foundation
import NIOCore

struct SSHExecResult {
    let output: String
    let errors: String
    let status: Int
}

/// One-off commands on an open connection, each on its own exec channel beside the interactive shell.
enum SSHRemoteExec {
    static func run(_ client: SSHClient, _ command: String, input: String? = nil, timeout: Duration) async -> SSHExecResult? {
        let work = Task { await collect(client, command, input: input) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        return result
    }

    /// Runs a script with `sh -s`; Citadel cannot half-close stdin, so the script ends itself with `exit`.
    static func script(_ client: SSHClient, _ body: String, timeout: Duration) async -> SSHExecResult? {
        let text = body.hasSuffix("\n") ? body : body + "\n"
        return await run(client, "sh -s", input: text + "exit\n", timeout: timeout)
    }

    private static func collect(_ client: SSHClient, _ command: String, input: String?) async -> SSHExecResult? {
        var output = ByteBuffer()
        var errors = ByteBuffer()
        var status = 0
        var completed = false
        do {
            try await client.withExec(command) { inbound, outbound in
                if let input { try await outbound.write(ByteBuffer(string: input)) }
                do {
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer): output.writeImmutableBuffer(buffer)
                        case .stderr(let buffer): errors.writeImmutableBuffer(buffer)
                        }
                    }
                } catch let failure as SSHClient.CommandFailed {
                    status = failure.exitCode
                }
                completed = true
            }
        } catch {
            // Citadel closes the exec channel after the command, which throws once the server has already closed it
            guard completed else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        return SSHExecResult(output: String(buffer: output), errors: String(buffer: errors), status: status)
    }
}
