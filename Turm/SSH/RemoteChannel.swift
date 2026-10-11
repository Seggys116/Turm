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
    func createBranch(named name: String, in directory: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a branch name." }
        guard let result = run(RemoteGit.createScript(named: trimmed, in: directory), timeout: 30) else {
            return "The host did not answer in time."
        }
        invalidate(prefix: "git:")
        guard result.status != 0 else { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not create \(trimmed)" : message
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

    func uploadTracked(
        _ url: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> String? {
        guard let result = run("d=\"${TMPDIR:-/tmp}\"; d=\"${d%/}/turm-$(id -u)\"; mkdir -p \"$d\" && chmod 700 \"$d\" && printf '%s' \"$d\""),
              result.status == 0, !result.output.isEmpty
        else { return nil }
        let directory = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = directory + "/" + Self.safeName(url.lastPathComponent)
        let channel = self
        return await Task.detached {
            guard channel.streamFile(url, to: path, isCancelled: isCancelled, progress: progress) else { return nil }
            return path
        }.value
    }

    func upload(
        _ url: URL,
        into directory: String,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> String? {
        let channel = self
        return await Task.detached {
            guard let plan = channel.planUpload(of: url, into: directory) else { return nil }
            for parent in plan.parents {
                guard channel.run("mkdir -p " + Self.quote(parent))?.status == 0 else { return nil }
            }
            var sent: Int64 = 0
            let total = max(plan.total, 1)
            for file in plan.files {
                if isCancelled() { return nil }
                let start = sent
                let size = FileCopy.byteCount(file.local)
                guard channel.streamFile(file.local, to: file.remote, isCancelled: isCancelled, progress: { amount, _ in
                    progress(start + amount, total)
                }) else { return nil }
                sent += size
                progress(sent, total)
            }
            progress(total, total)
            return directory
        }.value
    }

    func move(_ source: String, into directory: String) -> String? {
        guard FileDrop.canPlace(source, into: directory, move: true) else { return nil }
        let listed = listDirectory(directory)
        guard listed.failure == nil else { return "Could not read \(directory)." }
        let name = FileNames.suffixed((source as NSString).lastPathComponent, existing: Set(listed.entries.map(\.name)))
        let destination = (directory as NSString).appendingPathComponent(name)
        guard run("mv " + Self.quote(source) + " " + Self.quote(destination))?.status == 0 else {
            return "Could not move \((source as NSString).lastPathComponent)."
        }
        return nil
    }

    func delete(_ path: String) -> String? {
        guard !path.isEmpty, path != "/", path != ".", path != ".." else { return "Could not delete that." }
        guard run("rm -rf " + Self.quote(path))?.status == 0 else {
            return "Could not delete \((path as NSString).lastPathComponent)."
        }
        return nil
    }

    private struct PlannedUpload: Sendable {
        var files: [(local: URL, remote: String)]
        var parents: [String]
        var total: Int64
    }

    private func planUpload(of url: URL, into directory: String) -> PlannedUpload? {
        let listed = listDirectory(directory)
        guard listed.failure == nil else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let top = FileNames.suffixed(url.lastPathComponent, existing: Set(listed.entries.map(\.name)))
        let root = (directory as NSString).appendingPathComponent(top)
        if !isDirectory.boolValue {
            return PlannedUpload(files: [(url, root)], parents: [directory], total: FileCopy.byteCount(url))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var files: [(URL, String)] = []
        var parents: Set<String> = [root]
        var total: Int64 = 0
        for case let item as URL in enumerator {
            var relative = item.path
            if relative.hasPrefix(url.path) { relative = String(relative.dropFirst(url.path.count)) }
            if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            let remote = (root as NSString).appendingPathComponent(relative)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                parents.insert(remote)
            } else if values?.isRegularFile == true {
                files.append((item, remote))
                parents.insert((remote as NSString).deletingLastPathComponent)
                total += FileCopy.byteCount(item)
            }
        }
        return PlannedUpload(files: files, parents: Array(parents), total: total)
    }

    private func streamFile(
        _ url: URL,
        to path: String,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) -> Bool {
        guard let reading = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? reading.close() }
        let total = max(FileCopy.byteCount(url), 1)
        var sent: Int64 = 0
        var started = false
        while true {
            if isCancelled() {
                _ = run("rm -f " + Self.quote(path))
                return false
            }
            let data = (try? reading.read(upToCount: FileCopy.chunk)) ?? Data()
            if data.isEmpty { break }
            let op = started ? "cat >> " : "cat > "
            started = true
            guard send(data, command: op + Self.quote(path))?.status == 0 else {
                _ = run("rm -f " + Self.quote(path))
                return false
            }
            sent += Int64(data.count)
            progress(sent, total)
        }
        if !started, send(Data(), command: "cat > " + Self.quote(path))?.status != 0 {
            return false
        }
        progress(max(sent, total), total)
        return true
    }

    func listDirectory(_ path: String) -> ListedDirectory {
        guard let result = run(RemoteFiles.listScript(path), timeout: 20) else {
            return ListedDirectory(path: path, entries: [], failure: "The host did not answer.")
        }
        if result.status == 3 {
            return ListedDirectory(path: path, entries: [], failure: "Could not read \(path).")
        }
        guard result.status == 0 else {
            return ListedDirectory(path: path, entries: [], failure: "Could not read \(path).")
        }
        return RemoteFiles.parseListing(result.output, directory: path)
    }

    func directoriesWithVisibleEntries(_ paths: [String], includeHidden: Bool) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        guard let result = run(RemoteFiles.visibleDirectoriesScript(paths, includeHidden: includeHidden), timeout: 20),
              result.status == 0
        else { return Set(paths) }
        return RemoteFiles.parseVisibleDirectories(result.output)
    }

    func readFileText(_ path: String) -> RemoteFileText {
        guard let result = run(RemoteFiles.readScript(path), timeout: 20) else { return .failure("The host did not answer.") }
        switch result.status {
        case 0:
            if result.output.contains("\0") { return .failure("This file isn’t text.") }
            return .text(result.output)
        case 4:
            return .failure("Could not read \(path).")
        case 5:
            return .failure("This file is too large to open here.")
        default:
            return .failure("Could not read \(path).")
        }
    }

    func readFileData(_ path: String) -> RemoteFileText {
        guard let result = run(RemoteFiles.readEncodedScript(path), timeout: 60) else { return .failure("The host did not answer.") }
        switch result.status {
        case 0:
            guard let data = Data(base64Encoded: result.output, options: .ignoreUnknownCharacters) else {
                return .failure("Could not read \(path).")
            }
            return .data(data)
        case 4:
            return .failure("Could not read \(path).")
        case 5:
            return .failure("This file is too large to open here.")
        default:
            return .failure("Could not read \(path).")
        }
    }

    func writeFileText(_ path: String, text: String) -> String? {
        let result = send(Data(text.utf8), command: "cat > " + Self.quote(path))
        guard result?.status == 0 else { return "Could not save \(path)." }
        return nil
    }

    static func safeName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "file" : String(cleaned.suffix(80))
    }
}

enum RemoteFileText: Sendable {
    case text(String)
    case data(Data)
    case failure(String)
}
