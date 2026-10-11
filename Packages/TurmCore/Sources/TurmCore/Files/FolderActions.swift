import Foundation

public nonisolated enum FolderActions {
    public static func offersChangeDirectory(folder: String, workingDirectory: String) -> Bool {
        let folder = normalize(folder)
        let working = normalize(workingDirectory)
        guard !folder.isEmpty, !working.isEmpty else { return false }
        return folder != working
    }

    public static func offersFiles(folder: String) -> Bool {
        !normalize(folder).isEmpty
    }

    public static func normalize(_ path: String) -> String {
        guard path != "/" else { return "/" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
