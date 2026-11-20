import Darwin
import Foundation
import Testing
@testable import Turm

/// Whether a process id still names a process, a zombie included: a zombie stays until its parent collects it.
private func exists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(120), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    var late = 0
    while ContinuousClock.now < deadline || late < 10 {
        if ContinuousClock.now >= deadline { late += 1 }
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(late > 0 ? 200 : 50))
    }
    return condition()
}

@MainActor
struct ChildReaperTests {
    @Test func anExitedChildIsCollected() async throws {
        var pid: pid_t = 0
        let path = "/usr/bin/true"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        #expect(posix_spawn(&pid, path, nil, nil, &argv, environ) == 0)
        // nothing collects it yet, so it lingers as a zombie
        try await Task.sleep(for: .milliseconds(300))
        #expect(exists(pid))
        ChildReaper.collect(pid)
        #expect(await waitUntil { !exists(pid) })
    }

    @Test func aChildStillRunningIsCollectedWhenItExits() async throws {
        var pid: pid_t = 0
        let path = "/bin/sleep"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("1"), nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        #expect(posix_spawn(&pid, path, nil, nil, &argv, environ) == 0)
        ChildReaper.collect(pid)
        #expect(exists(pid))
        #expect(await waitUntil { !exists(pid) })
    }

    /// A closed session's shell must not linger as a zombie: enough of them stop new shells from starting.
    @Test func aClosedSessionLeavesNoZombie() async throws {
        let session = TerminalSession()
        let ready = await waitUntil { session.phase == .ready }
        #expect(ready, "shell never ready: \(session.bytesReceived) bytes")
        let pid = session.shellPid
        #expect(pid > 0)
        session.terminate()
        #expect(await waitUntil { !exists(pid) }, "shell \(pid) was never collected")
    }
}
