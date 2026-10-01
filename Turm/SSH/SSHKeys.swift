import Foundation
import TurmCore

nonisolated extension SSHKeys {
    private static let skipped: Set<String> = ["known_hosts", "known_hosts.old", "config", "authorized_keys", "authorized_keys2", "environment", "rc"]

    static func discover(in directory: String = NSHomeDirectory() + "/.ssh") -> [SSHKey] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), !name.hasSuffix(".pub"), !skipped.contains(name) else { return nil }
            let path = directory + "/" + name
            guard isPrivateKey(atPath: path) else { return nil }
            let publicLine = (try? String(contentsOfFile: path + ".pub", encoding: .utf8)) ?? ""
            let parsed = parsePublicKey(publicLine)
            return SSHKey(path: path, type: parsed?.type ?? "", comment: parsed?.comment ?? "", fingerprint: parsed?.fingerprint)
        }
    }

    static func isPrivateKey(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let handle = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 80)) ?? Data(), as: UTF8.self)
        return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY-----")
    }

    @concurrent
    static func detect(_ host: SSHHost, keys: [SSHKey]) async -> SSHKeyDetection {
        guard !keys.isEmpty else { return .none }
        var arguments = [
            "-v", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "IdentitiesOnly=yes",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]
        for key in keys { arguments += ["-i", key.path] }
        if let port = host.port { arguments += ["-p", String(port)] }
        arguments += ["--", host.destination, "exit 0"]
        guard let result = SSHProcess.run(arguments, timeout: 20) else { return .unreachable("ssh did not finish in time") }
        if let found = acceptedKey(inVerboseOutput: result.errors) {
            return .accepted(path: found.path, authenticated: found.authenticated)
        }
        if result.errors.contains("Host key verification failed") { return .hostKeyUnknown }
        if result.errors.contains("Permission denied") { return .none }
        let reason = result.errors.split(whereSeparator: \.isNewline).last { !$0.hasPrefix("debug") }.map(String.init)
        return .unreachable(reason ?? "ssh exited with status \(result.status)")
    }
}

nonisolated struct SSHProcessResult: Sendable {
    let status: Int32
    let output: String
    let errors: String
}

nonisolated enum SSHProcess {
    nonisolated(unsafe) static var executable = "/usr/bin/ssh"

    private static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    static func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval) -> SSHProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.removeValue(forKey: "DISPLAY")
        process.environment = environment
        let output = SpawnGuard.pipe()
        let errors = SpawnGuard.pipe()
        let stdin = SpawnGuard.pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.qualityOfService = .userInitiated
        do {
            try process.run()
        } catch {
            return nil
        }
        let outBuffer = OutputBuffer()
        let errBuffer = OutputBuffer()
        let group = DispatchGroup()
        for (pipe, buffer) in [(output, outBuffer), (errors, errBuffer)] {
            group.enter()
            let reader = pipe.fileHandleForReading
            start {
                buffer.set(reader.readDataToEndOfFile())
                group.leave()
            }
        }
        if let input {
            let writer = stdin.fileHandleForWriting
            start {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if group.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        process.waitUntilExit()
        return SSHProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outBuffer.get(), as: UTF8.self),
            errors: String(decoding: errBuffer.get(), as: UTF8.self)
        )
    }
}
