import Darwin
import Foundation
import Testing
@testable import Turm

/// Sends window-size signals to a shell from another thread until stopped.
private final class ResizeStorm: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    func start(_ pid: pid_t) {
        Thread.detachNewThread { [self] in
            while isRunning {
                kill(pid, SIGWINCH)
                usleep(2_000)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

@MainActor
@Suite(.serialized)
struct ShellSignalTests {
    /// While Turm is busy its shell's writes block, and a pane being laid out or resized sends the shell window-size
    /// signals. A signal that interrupts the integration's write must not lose the prompt marker, or the session
    /// never becomes ready (and a finished command never ends).
    static let shells = ["/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(arguments: shells)
    func theShellReachesItsPromptThroughResizeSignals(_ shell: String) async throws {
        for attempt in 0..<5 {
            // a large environment makes the shell's first report far bigger than the terminal's buffer
            setenv("TURM_TEST_PADDING", String(repeating: "x", count: 120_000), 1)
            ShellIntegration.forcedShell = shell
            let session = TerminalSession()
            ShellIntegration.forcedShell = nil
            unsetenv("TURM_TEST_PADDING")
            defer { session.terminate() }
            let pid = session.shellPid
            #expect(pid > 0)
            let storm = ResizeStorm()
            storm.start(pid)
            // hold the main thread so the shell's report fills the terminal's buffer and its write blocks
            let busy = ContinuousClock.now + .milliseconds(1500)
            while ContinuousClock.now < busy { usleep(1_000) }
            try await Task.sleep(for: .milliseconds(500))
            storm.stop()
            let deadline = ContinuousClock.now + .seconds(60)
            while session.phase != .ready, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let tail = String(decoding: session.recentOutput.suffix(200), as: UTF8.self)
            #expect(session.phase == .ready, "\(shell) attempt \(attempt): \(session.bytesReceived) bytes, last: \(tail)")
            guard session.phase == .ready else { return }
        }
    }
}
