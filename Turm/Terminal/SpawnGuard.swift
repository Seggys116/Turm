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
