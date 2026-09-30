import Foundation

nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    func set(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

nonisolated enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: String? = nil,
        timeout: TimeInterval,
        requireSuccess: Bool = false
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = SpawnGuard.pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        let buffer = OutputBuffer()
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            buffer.set(reader.readDataToEndOfFile())
            finished.signal()
        }

        func abort() {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            abort()
            return nil
        }
        while process.isRunning {
            if Date() >= deadline {
                abort()
                return nil
            }
            usleep(5000)
        }
        guard process.terminationReason == .exit, !requireSuccess || process.terminationStatus == 0 else { return nil }
        return String(decoding: buffer.get(), as: UTF8.self)
    }

    static func locate(_ name: String, in directories: [String]) -> String? {
        for directory in directories {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
