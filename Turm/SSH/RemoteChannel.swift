import Foundation
import TurmCore

nonisolated final class RemoteChannel: @unchecked Sendable {
    let socket: String
    private let lock = NSLock()
    private var storedEnvironment: [String: String] = [:]
    private var cache: [String: (value: Any, stored: Date)] = [:]

    init(socket: String) {
        self.socket = socket
    }

    var environment: [String: String] {
        get { locked { storedEnvironment } }
        set {
            locked {
                if storedEnvironment["PATH"] != newValue["PATH"] { cache.removeAll() }
                storedEnvironment = newValue
            }
        }
    }

    var home: String? { environment["HOME"] }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let gatesLock = NSLock()
    nonisolated(unsafe) private static var gates: [String: NSLock] = [:]

    static func multiplexed(_ socket: String) -> [String] {
        [
            "-o", "ControlMaster=no", "-o", "ControlPath=\(socket)", "-o", "ProxyCommand=/usr/bin/false",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        ]
    }

    static func session(on socket: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) -> SSHProcessResult? {
        gatesLock.lock()
        let gate = gates[socket] ?? NSLock()
        gates[socket] = gate
        gatesLock.unlock()
        gate.lock()
        defer { gate.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while true {
            let remaining = max(deadline.timeIntervalSinceNow, 1)
            let result = SSHProcess.run(multiplexed(socket) + arguments, input: input, timeout: remaining)
            guard let result, result.status == 255, isRefused(result.errors), attempt < 4, Date() < deadline else { return result }
            attempt += 1
            usleep(useconds_t(150_000 * attempt))
        }
    }

    static func isRefused(_ errors: String) -> Bool {
        errors.contains("Session open refused") || errors.contains("mux_client_request_session")
    }

    func run(_ script: String, timeout: TimeInterval = 5) -> SSHProcessResult? {
        Self.session(on: socket, ["-T", "turm", "sh -s"], input: Data(script.utf8), timeout: timeout)
    }

    func send(_ data: Data, command: String, timeout: TimeInterval = 60) -> SSHProcessResult? {
        Self.session(on: socket, ["-T", "turm", "sh -c " + Self.quote(command)], input: data, timeout: timeout)
    }

    func cached<T>(_ key: String, for ttl: TimeInterval, _ load: () -> T?) -> T? {
        if let hit = locked({ cache[key] }), Date().timeIntervalSince(hit.stored) < ttl, let value = hit.value as? T {
            return value
        }
        guard let value = load() else { return nil }
        locked { cache[key] = (value, Date()) }
        return value
    }

    func invalidate(prefix: String) {
        locked { cache = cache.filter { !$0.key.hasPrefix(prefix) } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

nonisolated extension RemoteChannel {
    @concurrent
    func gitStatus(in directory: String) async -> GitStatus? {
        guard let result = run(RemoteGit.statusScript(in: directory)), result.status == 0 else { return nil }
        return Self.parseGitStatus(result.output)
    }

    static func parseGitStatus(_ output: String) -> GitStatus? {
        guard let git = RemoteGit.parseStatus(output) else { return nil }
        return GitStatus(branch: git.branch, files: git.files, added: git.added, removed: git.removed)
    }

    @concurrent
    func branches(in directory: String) async -> [String] {
        guard let result = run(RemoteGit.branchesScript(in: directory)), result.status == 0 else { return [] }
        return RemoteGit.branches(from: result.output)
    }

    @concurrent
    func switchBranch(to name: String, in directory: String) async -> String? {
        guard let result = run(RemoteGit.switchScript(to: name, in: directory), timeout: 30) else {
            return "The host did not answer in time."
        }
        invalidate(prefix: "git:")
        guard result.status != 0 else { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not switch to \(name)" : message
    }

    @concurrent
    func upload(_ urls: [URL]) async -> [URL: String] {
        let token = UUID().uuidString.prefix(8).lowercased()
        guard let result = run("d=\"${TMPDIR:-/tmp}\"; d=\"${d%/}/turm-$(id -u)\"; mkdir -p \"$d\" && chmod 700 \"$d\" && printf '%s' \"$d\""),
              result.status == 0, !result.output.isEmpty
        else { return [:] }
        let directory = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var paths: [URL: String] = [:]
        for (index, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let name = Self.safeName(url.lastPathComponent)
            let path = directory + "/" + token + "-" + String(index) + "-" + name
            guard let sent = send(data, command: "cat > " + Self.quote(path)), sent.status == 0 else { continue }
            paths[url] = path
        }
        return paths
    }

    static func safeName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "file" : String(cleaned.suffix(80))
    }
}
