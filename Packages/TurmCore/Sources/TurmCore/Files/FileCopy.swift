import Foundation

public nonisolated enum FileCopy {
    public static let chunk = 256 * 1024

    public static func transfer(
        from source: URL,
        to destination: URL,
        move: Bool,
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) throws {
        if isCancelled() { throw FileDropError.cancelled }
        let sourceURL = source.standardizedFileURL
        let total = byteCount(sourceURL)
        let folder = destination.deletingLastPathComponent()
        if move, device(sourceURL) == device(folder) {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            onProgress(max(total, 1), max(total, 1))
            return
        }
        var sent: Int64 = 0
        try copy(sourceURL, to: destination, sent: &sent, total: max(total, 1), isCancelled: isCancelled, onProgress: onProgress)
        if isCancelled() {
            try? FileManager.default.removeItem(at: destination)
            throw FileDropError.cancelled
        }
        if move { try FileManager.default.removeItem(at: sourceURL) }
        onProgress(max(total, sent), max(total, 1))
    }

    public static func byteCount(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return 0 }
            return children.reduce(0) { $0 + byteCount($1) }
        }
        return Int64(values?.fileSize ?? 0)
    }

    private static func copy(
        _ source: URL,
        to destination: URL,
        sent: inout Int64,
        total: Int64,
        isCancelled: () -> Bool,
        onProgress: (Int64, Int64) -> Void
    ) throws {
        if isCancelled() { throw FileDropError.cancelled }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                try copy(
                    child,
                    to: destination.appendingPathComponent(child.lastPathComponent),
                    sent: &sent,
                    total: total,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                )
            }
            return
        }
        let reading = try FileHandle(forReadingFrom: source)
        defer { try? reading.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writing = try FileHandle(forWritingTo: destination)
        defer { try? writing.close() }
        while true {
            if isCancelled() {
                try? FileManager.default.removeItem(at: destination)
                throw FileDropError.cancelled
            }
            let data = try reading.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try writing.write(contentsOf: data)
            sent += Int64(data.count)
            onProgress(sent, total)
        }
    }

    private static func device(_ url: URL) -> Int32? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
