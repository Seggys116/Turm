import Foundation

public nonisolated enum CompanionFileLimits {
    public static let maxListing = 5_000
    public static let maxRead = 8 * 1024 * 1024
    public static let maxWrite = 32 * 1024 * 1024
    public static let maxDiff = 1 * 1024 * 1024

    public static func cappedText(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        if text.isEmpty { return ("", false) }
        if text.utf8.count <= limit { return (text, false) }
        var result = ""
        var byteCount = 0
        for character in text {
            let charByteCount = character.utf8.count
            if byteCount + charByteCount > limit { break }
            byteCount += charByteCount
            result.append(character)
        }
        return (result, true)
    }

    public static func cappedData(_ data: Data, limit: Int) -> (data: Data, truncated: Bool) {
        if data.count <= limit { return (data, false) }
        return (data.prefix(limit), true)
    }
}

public nonisolated enum CompanionWriteDecision: Sendable, Equatable {
    case allow(path: String)
    case refuse(String)
}

public nonisolated enum CompanionWrites {
    public static func decide(
        uploadsEnabled: Bool,
        path: String,
        allowedRoot: String,
        overwrite: Bool,
        exists: Bool
    ) -> CompanionWriteDecision {
        guard uploadsEnabled else {
            return .refuse("uploads are disabled")
        }
        guard !allowedRoot.isEmpty, allowedRoot.hasPrefix("/"), !allowedRoot.contains("\0") else {
            return .refuse("allowed root is invalid")
        }
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
            return .refuse("path is invalid")
        }
        let normalizedRoot = normalize(allowedRoot)
        let normalizedPath = normalize(path)
        guard isDescendant(path: normalizedPath, of: normalizedRoot) else {
            return .refuse("path is outside the allowed root")
        }
        if exists && !overwrite {
            return .refuse("file already exists")
        }
        return .allow(path: normalizedPath)
    }

    private static func isDescendant(path: String, of root: String) -> Bool {
        if root == "/" {
            return path != "/"
        }
        return path.hasPrefix(root + "/")
    }

    private static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                break
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        let joined = components.joined(separator: "/")
        return "/" + joined
    }
}
