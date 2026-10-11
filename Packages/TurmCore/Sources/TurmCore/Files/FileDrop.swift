import Foundation

public nonisolated enum FileDropError: Error, Sendable, Equatable {
    case notAllowed
    case cancelled
}

public nonisolated enum FileDrop {
    public static let moveType = "com.zak-noble-clarke.turm.file-move"

    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func canPlace(_ source: String, into directory: String, move: Bool) -> Bool {
        let source = normalized(source)
        let directory = normalized(directory)
        guard source != directory else { return false }
        guard !directory.hasPrefix(source + "/") else { return false }
        if move {
            let parent = normalized((source as NSString).deletingLastPathComponent)
            if parent == directory { return false }
        }
        return true
    }

    public static func destination(named name: String, into directory: String, existing: Set<String>) -> String {
        let unique = FileNames.suffixed(name, existing: existing)
        return URL(fileURLWithPath: directory).appendingPathComponent(unique).path
    }

    @discardableResult
    public static func place(
        source: URL, into directory: String, move: Bool, fileManager: FileManager = .default
    ) throws -> URL? {
        let sourceURL = source.standardizedFileURL
        guard canPlace(sourceURL.path, into: directory, move: move) else { return nil }
        let names = Set((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
        let destination = URL(fileURLWithPath: destination(
            named: sourceURL.lastPathComponent, into: directory, existing: names
        ))
        if move {
            try fileManager.moveItem(at: sourceURL, to: destination)
        } else {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            try fileManager.copyItem(at: accessing ? source : sourceURL, to: destination)
        }
        return destination
    }
}
