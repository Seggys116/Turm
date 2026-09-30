import Foundation

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
    private static let gitPrelude = "export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0\n"

    private func inDirectory(_ directory: String, _ body: String) -> String {
        Self.gitPrelude + "cd " + Self.quote(directory) + " 2>/dev/null || exit 3\n" + body
    }

    @concurrent
    func gitStatus(in directory: String) async -> GitStatus? {
        let script = inDirectory(directory, """
            branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || exit 4
            printf '%s\\n' "$branch"
            git diff HEAD --numstat 2>/dev/null
            """)
        guard let result = run(script), result.status == 0 else { return nil }
        return Self.parseGitStatus(result.output)
    }

    static func parseGitStatus(_ output: String) -> GitStatus? {
        guard let newline = output.firstIndex(of: "\n") else {
            let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : GitStatus(branch: name, files: 0, added: 0, removed: 0)
        }
        let name = output[..<newline].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let totals = GitInspector.parseNumstat(String(output[output.index(after: newline)...]))
        return GitStatus(branch: name, files: totals.files, added: totals.added, removed: totals.removed)
    }

    @concurrent
    func branches(in directory: String) async -> [String] {
        let script = inDirectory(directory, "git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads")
        guard let result = run(script), result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    @concurrent
    func switchBranch(to name: String, in directory: String) async -> String? {
        guard let result = run(inDirectory(directory, "git switch " + Self.quote(name) + " 2>&1"), timeout: 30) else {
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
