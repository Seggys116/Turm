import Foundation

public nonisolated struct FileEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var kind: String
    public var isHidden: Bool { name.hasPrefix(".") }
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64?, modified: Date?, kind: String) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind
    }
}

public nonisolated struct ListedDirectory: Sendable, Equatable {
    public var path: String
    public var entries: [FileEntry]
    public var failure: String?

    public init(path: String, entries: [FileEntry], failure: String? = nil) {
        self.path = path
        self.entries = entries
        self.failure = failure
    }
}

public nonisolated enum FileListing {
    public static func present(_ entries: [FileEntry], includeHidden: Bool, filter: String) -> [FileEntry] {
        var result = entries
        if !includeHidden {
            result = result.filter { !$0.isHidden }
        }
        if !filter.isEmpty {
            result = result.filter { $0.name.range(of: filter, options: .caseInsensitive) != nil }
        }
        let folders = result
            .filter { $0.isDirectory }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let files = result
            .filter { !$0.isDirectory }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders + files
    }

    public static func kind(name: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return "File" }
        return ext.uppercased()
    }
}

public nonisolated enum LocalDirectory {
    public static func list(_ path: String, fileManager: FileManager = .default) -> ListedDirectory {
        do {
            let names = try fileManager.contentsOfDirectory(atPath: path)
            var entries: [FileEntry] = []
            for name in names {
                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
                var size: Int64? = nil
                var modified: Date? = nil
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath) {
                    if let v = attrs[.size] as? Int64 {
                        size = v
                    } else if let v = attrs[.size] as? NSNumber {
                        size = v.int64Value
                    }
                    modified = attrs[.modificationDate] as? Date
                }
                entries.append(FileEntry(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir.boolValue,
                    size: isDir.boolValue ? nil : size,
                    modified: modified,
                    kind: FileListing.kind(name: name, isDirectory: isDir.boolValue)
                ))
            }
            return ListedDirectory(path: path, entries: entries)
        } catch {
            return ListedDirectory(
                path: path,
                entries: [],
                failure: "Could not read \(path): \(error.localizedDescription)"
            )
        }
    }

    /// Directories among `paths` that contain at least one entry the sidebar would show.
    /// A path that cannot be read is included, so the row can still open and show the error.
    public static func directoriesWithVisibleEntries(_ paths: [String], includeHidden: Bool, fileManager: FileManager = .default) -> Set<String> {
        Set(paths.filter { containsVisibleEntry($0, includeHidden: includeHidden, fileManager: fileManager) })
    }

    public static func containsVisibleEntry(_ path: String, includeHidden: Bool, fileManager: FileManager = .default) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return true }
        if includeHidden { return !names.isEmpty }
        return names.contains { !$0.hasPrefix(".") }
    }
}

public nonisolated enum RemoteFiles {
    public static func listScript(_ directory: String) -> String {
        """
        cd \(RemoteGit.quote(directory)) 2>/dev/null || exit 3
        find . -mindepth 1 -maxdepth 1 -print | while IFS= read -r path; do
          name=${path#./}
          if [ -d "$path" ]; then
            printf 'd\\t\\t%s\\n' "$name"
          else
            size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
            printf 'f\\t%s\\t%s\\n' "$size" "$name"
          fi
        done
        """
    }

    public static func parseListing(_ text: String, directory: String) -> ListedDirectory {
        var entries: [FileEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let name = String(parts[2])
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let isDirectory = parts[0] == "d"
            let size = Int64(parts[1])
            let path = (directory as NSString).appendingPathComponent(name)
            entries.append(FileEntry(
                name: name,
                path: path,
                isDirectory: isDirectory,
                size: isDirectory ? nil : size,
                modified: nil,
                kind: FileListing.kind(name: name, isDirectory: isDirectory)
            ))
        }
        return ListedDirectory(path: directory, entries: entries)
    }

    public static func visibleDirectoriesScript(_ paths: [String], includeHidden: Bool) -> String {
        let filter = includeHidden ? "" : " ! -name '.*'"
        return paths.map { path in
            let quoted = RemoteGit.quote(path)
            return "hit=$(find \(quoted) -mindepth 1 -maxdepth 1\(filter) -print 2>/dev/null | head -n 1); [ -n \"$hit\" ] && printf '%s\\n' \(quoted)"
        }.joined(separator: "\n")
    }

    public static func parseVisibleDirectories(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) })
    }

    public static let maxReadBytes = 1_000_000
    public static let maxMediaBytes = 32 * 1_000_000

    public static func readScript(_ path: String) -> String {
        readScript(path, limit: maxReadBytes, encode: false)
    }

    public static func readEncodedScript(_ path: String) -> String {
        readScript(path, limit: maxMediaBytes, encode: true)
    }

    public static func writeEncodedScript(_ path: String, encoded: String) -> String {
        """
        base64 -d > \(RemoteGit.quote(path)) <<'TURM'
        \(encoded)
        TURM
        """
    }

    private static func readScript(_ path: String, limit: Int, encode: Bool) -> String {
        let quoted = RemoteGit.quote(path)
        let body = encode ? "base64 < \"$p\"" : "cat \"$p\""
        return """
        p=\(quoted)
        [ -f "$p" ] || exit 4
        size=$(wc -c < "$p" 2>/dev/null | tr -d '[:space:]')
        [ "${size:-0}" -le \(limit) ] || exit 5
        \(body)
        """
    }
}

public nonisolated enum FileNames {
    public static func suffixed(_ name: String, existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}

public nonisolated struct TransferProgress: Sendable, Equatable {
    public var transferred: Int64
    public var total: Int64?
    public var isCancelled: Bool

    public var fraction: Double? {
        guard let t = total, t > 0 else { return nil }
        return Double(transferred) / Double(t)
    }

    public init(transferred: Int64, total: Int64?, isCancelled: Bool = false) {
        self.transferred = transferred
        self.total = total
        self.isCancelled = isCancelled
    }

    public func advanced(by bytes: Int64) -> TransferProgress {
        TransferProgress(transferred: transferred + bytes, total: total, isCancelled: isCancelled)
    }

    public func cancelled() -> TransferProgress {
        TransferProgress(transferred: transferred, total: total, isCancelled: true)
    }
}

public nonisolated enum FileTransferError: Error, Sendable, Equatable {
    case fileExists(String)
    case cancelled
    case disconnected
    case notFound(String)
}

public nonisolated struct MemoryFiles: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var data: Data?
        public var isDirectory: Bool

        public init(data: Data? = nil, isDirectory: Bool) {
            self.data = data
            self.isDirectory = isDirectory
        }
    }

    public var nodes: [String: Node]
    public var connected: Bool

    public init(nodes: [String: Node] = [:], connected: Bool = true) {
        self.nodes = nodes
        self.connected = connected
    }

    public func list(directory: String) throws -> [FileEntry] {
        guard connected else { throw FileTransferError.disconnected }
        guard let node = nodes[directory], node.isDirectory else {
            throw FileTransferError.notFound(directory)
        }
        let prefix = directory == "/" ? "/" : directory + "/"
        var result: [FileEntry] = []
        for (path, node) in nodes {
            guard path != directory else { continue }
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard !remainder.isEmpty, !remainder.contains("/") else { continue }
            result.append(FileEntry(
                name: remainder,
                path: path,
                isDirectory: node.isDirectory,
                size: node.data.map { Int64($0.count) },
                modified: nil,
                kind: FileListing.kind(name: remainder, isDirectory: node.isDirectory)
            ))
        }
        return result
    }

    public func download(path: String) throws -> Data {
        guard connected else { throw FileTransferError.disconnected }
        guard let node = nodes[path], !node.isDirectory, let data = node.data else {
            throw FileTransferError.notFound(path)
        }
        return data
    }

    public mutating func upload(_ data: Data, to path: String, overwrite: Bool) throws {
        guard connected else { throw FileTransferError.disconnected }
        if nodes[path] != nil, !overwrite {
            throw FileTransferError.fileExists(path)
        }
        let parentCandidate = (path as NSString).deletingLastPathComponent
        let parent = parentCandidate.isEmpty ? "/" : parentCandidate
        if parent != path {
            guard let parentNode = nodes[parent], parentNode.isDirectory else {
                throw FileTransferError.notFound(parent)
            }
        }
        nodes[path] = Node(data: data, isDirectory: false)
    }
}

public nonisolated protocol RemoteFileSystem: Sendable {
    func list(directory: String) async throws -> [FileEntry]
    func download(path: String) async throws -> Data
    func upload(_ data: Data, to path: String, overwrite: Bool) async throws
}
