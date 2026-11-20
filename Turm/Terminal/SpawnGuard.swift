import Darwin
import Foundation

nonisolated enum SpawnGuard {
    private static let lock = NSLock()

    static func forking<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func pipe() -> Pipe {
        forking {
            let pipe = Pipe()
            for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
                let flags = fcntl(descriptor, F_GETFD)
                if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
            }
            return pipe
        }
    }
}

/// Collects the exit of a shell Turm has stopped. SwiftTerm's `LocalProcess.terminate()` cancels its own exit watcher
/// before the shell has gone, so without this every closed session and restarted completion shell stays a zombie
/// until Turm quits, and enough of them use up the user's process limit so that new shells cannot start.
nonisolated enum ChildReaper {
    private static let queue = DispatchQueue(label: "turm.child-reaper")
    /// Only touched on `queue`.
    nonisolated(unsafe) private static var watchers: [pid_t: DispatchSourceProcess] = [:]

    static func collect(_ pid: pid_t) {
        guard pid > 0 else { return }
        queue.async {
            guard !reap(pid) else { return }
            let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            watcher.setEventHandler {
                guard reap(pid) else { return }
                watchers[pid]?.cancel()
                watchers[pid] = nil
            }
            watchers[pid] = watcher
            watcher.activate()
            // the shell may have exited between the first check and the watcher starting
            if reap(pid) {
                watcher.cancel()
                watchers[pid] = nil
            }
        }
    }

    /// Whether the child is gone: collected now, or no longer a child of Turm.
    private static func reap(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid || (result == -1 && errno == ECHILD)
    }
}
