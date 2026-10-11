import Foundation

public nonisolated enum GitDiffStatus: String, Codable, Sendable, Equatable {
    case modified, added, deleted, renamed, binary
}

public nonisolated enum GitDiffLineKind: Sendable, Equatable {
    case context, added, removed
}

public nonisolated struct GitDiffLine: Sendable, Equatable {
    public var kind: GitDiffLineKind
    public var text: String

    public init(kind: GitDiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public nonisolated struct GitHunk: Sendable, Equatable, Identifiable {
    public var id: String
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [GitDiffLine]

    public init(id: String, header: String, oldStart: Int, newStart: Int, lines: [GitDiffLine]) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

public nonisolated struct GitDiffFile: Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var oldPath: String?
    public var status: GitDiffStatus
    public var hunks: [GitHunk]
    public var truncated: Bool

    public var shownLines: Int {
        hunks.reduce(0) { $0 + $1.lines.count }
    }

    public init(id: String, path: String, oldPath: String?, status: GitDiffStatus, hunks: [GitHunk], truncated: Bool) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.hunks = hunks
        self.truncated = truncated
    }
}

public nonisolated struct GitDiffDocument: Sendable, Equatable {
    public var files: [GitDiffFile]

    public init(files: [GitDiffFile]) {
        self.files = files
    }
}

public nonisolated struct GitCommitRef: Sendable, Equatable, Identifiable {
    public var sha: String
    public var subject: String
    public var id: String { sha }

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

public nonisolated struct SideBySideRow: Sendable, Equatable {
    public var left: GitDiffLine?
    public var right: GitDiffLine?

    public init(left: GitDiffLine?, right: GitDiffLine?) {
        self.left = left
        self.right = right
    }
}

public nonisolated enum GitDiffParser {
    public static let defaultLineCap = 2_000

    public static func parse(_ text: String, lineCap: Int? = defaultLineCap) -> GitDiffDocument {
        guard !text.isEmpty else { return GitDiffDocument(files: []) }
        var blocks: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                if !current.isEmpty { blocks.append(current) }
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return GitDiffDocument(files: blocks.compactMap { parseBlock($0, lineCap: lineCap) })
    }

    private static func parseBlock(_ lines: [String], lineCap: Int?) -> GitDiffFile? {
        guard let first = lines.first, first.hasPrefix("diff --git ") else { return nil }
        let diffSuffix = String(first.dropFirst("diff --git ".count))
        let usesPrefixes = diffSuffix.hasPrefix("a/")

        var rawMinus: String? = nil
        var rawPlus: String? = nil
        var renameFrom: String? = nil
        var renameTo: String? = nil
        var newFile = false
        var deletedFile = false
        var isBinary = false

        var i = 1
        while i < lines.count && !lines[i].hasPrefix("@@ ") {
            let line = lines[i]
            if line.hasPrefix("--- ") {
                rawMinus = String(line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                rawPlus = String(line.dropFirst(4))
            } else if line.hasPrefix("rename from ") {
                renameFrom = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                renameTo = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("new file mode") {
                newFile = true
            } else if line.hasPrefix("deleted file mode") {
                deletedFile = true
            } else if line.hasPrefix("Binary files ") {
                isBinary = true
            }
            i += 1
        }

        let path: String
        let oldPath: String?
        var status: GitDiffStatus

        if renameFrom != nil || renameTo != nil {
            status = .renamed
            oldPath = renameFrom
            path = renameTo ?? ""
        } else if newFile || rawMinus == "/dev/null" {
            status = .added
            oldPath = nil
            path = rawPlus.map { stripped($0, usesPrefixes: usesPrefixes, prefix: "b/") }
                ?? pathFromDiffSuffix(diffSuffix, usesPrefixes: usesPrefixes)
        } else if deletedFile || rawPlus == "/dev/null" {
            status = .deleted
            oldPath = nil
            path = rawMinus.map { stripped($0, usesPrefixes: usesPrefixes, prefix: "a/") }
                ?? pathFromDiffSuffix(diffSuffix, usesPrefixes: usesPrefixes)
        } else {
            status = .modified
            oldPath = nil
            path = rawPlus.map { stripped($0, usesPrefixes: usesPrefixes, prefix: "b/") }
                ?? rawMinus.map { stripped($0, usesPrefixes: usesPrefixes, prefix: "a/") }
                ?? pathFromDiffSuffix(diffSuffix, usesPrefixes: usesPrefixes)
        }

        var hunks: [GitHunk] = []
        var truncated = false
        var linesRemaining = lineCap

        while i < lines.count {
            let headerLine = lines[i]
            guard headerLine.hasPrefix("@@ ") else { i += 1; continue }
            guard let (oldStart, newStart) = parseHunkRange(headerLine) else { i += 1; continue }
            var diffLines: [GitDiffLine] = []
            var capped = false
            i += 1
            while i < lines.count && !lines[i].hasPrefix("@@ ") {
                let dl = lines[i]
                let kind: GitDiffLineKind?
                if dl.hasPrefix("+") { kind = .added }
                else if dl.hasPrefix("-") { kind = .removed }
                else if dl.hasPrefix(" ") { kind = .context }
                else { kind = nil }
                if let k = kind {
                    if let rem = linesRemaining, rem <= 0 {
                        capped = true
                    } else {
                        diffLines.append(GitDiffLine(kind: k, text: String(dl.dropFirst())))
                        if linesRemaining != nil { linesRemaining! -= 1 }
                    }
                }
                i += 1
            }
            if capped { truncated = true }
            hunks.append(GitHunk(
                id: "\(path):\(headerLine)",
                header: headerLine,
                oldStart: oldStart,
                newStart: newStart,
                lines: diffLines
            ))
        }

        if isBinary && hunks.isEmpty { status = .binary }

        return GitDiffFile(id: path, path: path, oldPath: oldPath, status: status, hunks: hunks, truncated: truncated)
    }

    private static func stripped(_ raw: String, usesPrefixes: Bool, prefix: String) -> String {
        usesPrefixes && raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    private static func pathFromDiffSuffix(_ diffSuffix: String, usesPrefixes: Bool) -> String {
        guard usesPrefixes else { return diffSuffix }
        if let range = diffSuffix.range(of: " b/", options: .backwards) {
            return String(diffSuffix[range.upperBound...])
        }
        return diffSuffix.hasPrefix("a/") ? String(diffSuffix.dropFirst(2)) : diffSuffix
    }

    private static func parseHunkRange(_ header: String) -> (Int, Int)? {
        guard header.hasPrefix("@@ -") else { return nil }
        var cur = header.index(header.startIndex, offsetBy: 4)
        let end = header.endIndex
        guard cur < end && header[cur].isNumber else { return nil }
        let oldBegin = cur
        while cur < end && header[cur].isNumber { cur = header.index(after: cur) }
        guard let oldStart = Int(header[oldBegin..<cur]) else { return nil }
        if cur < end && header[cur] == "," {
            cur = header.index(after: cur)
            while cur < end && header[cur].isNumber { cur = header.index(after: cur) }
        }
        guard cur < end && header[cur] == " " else { return nil }
        cur = header.index(after: cur)
        guard cur < end && header[cur] == "+" else { return nil }
        cur = header.index(after: cur)
        guard cur < end && header[cur].isNumber else { return nil }
        let newBegin = cur
        while cur < end && header[cur].isNumber { cur = header.index(after: cur) }
        guard let newStart = Int(header[newBegin..<cur]) else { return nil }
        return (oldStart, newStart)
    }

    public static func parseLog(_ text: String) -> [GitCommitRef] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let tabIdx = line.firstIndex(of: "\t") else { return nil }
            return GitCommitRef(
                sha: String(line[..<tabIdx]),
                subject: String(line[line.index(after: tabIdx)...])
            )
        }
    }

    public static func inlineChanges(old: String, new: String) -> (removed: [Range<String.Index>], added: [Range<String.Index>]) {
        let oldTokens = tokens(in: old)
        let newTokens = tokens(in: new)
        let unmatched = unmatchedTokens(oldTokens.map(\.text), newTokens.map(\.text))
        return (
            removed: ranges(oldTokens, changed: unmatched.old),
            added: ranges(newTokens, changed: unmatched.new)
        )
    }

    public static func inlineChanges(for lines: [GitDiffLine]) -> [[Range<String.Index>]] {
        var marks = Array(repeating: [Range<String.Index>](), count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            let removalStart = index
            while index < lines.count && lines[index].kind == .removed { index += 1 }
            let additionStart = index
            while index < lines.count && lines[index].kind == .added { index += 1 }
            let pairs = min(additionStart - removalStart, index - additionStart)
            for offset in 0..<pairs {
                let change = inlineChanges(old: lines[removalStart + offset].text, new: lines[additionStart + offset].text)
                marks[removalStart + offset] = change.removed
                marks[additionStart + offset] = change.added
            }
        }
        return marks
    }

    private struct LineToken {
        var text: String
        var range: Range<String.Index>
    }

    private static func tokens(in text: String) -> [LineToken] {
        var result: [LineToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            if startsMember(text, at: index) {
                index = text.index(after: index)
                index = consumeWord(text, from: index)
            } else if isWord(text[index]) {
                index = consumeWord(text, from: index)
            } else {
                while index < text.endIndex, !isWord(text[index]), !startsMember(text, at: index) {
                    index = text.index(after: index)
                }
            }
            result.append(LineToken(text: String(text[start..<index]), range: start..<index))
        }
        return result
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func startsMember(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == "." else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && isWord(text[next])
    }

    private static func consumeWord(_ text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, isWord(text[index]) { index = text.index(after: index) }
        return index
    }

    private static let inlineTokenCap = 400

    private static func unmatchedTokens(_ old: [String], _ new: [String]) -> (old: [Bool], new: [Bool]) {
        if old.count > inlineTokenCap || new.count > inlineTokenCap {
            return prefixSuffixUnmatched(old, new)
        }
        let rows = old.count + 1
        let columns = new.count + 1
        var scores = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        if old.count > 0 && new.count > 0 {
            for row in 1...old.count {
                for column in 1...new.count {
                    if old[row - 1] == new[column - 1] {
                        scores[row][column] = scores[row - 1][column - 1] + 1
                    } else {
                        scores[row][column] = max(scores[row - 1][column], scores[row][column - 1])
                    }
                }
            }
        }
        var oldChanged = Array(repeating: true, count: old.count)
        var newChanged = Array(repeating: true, count: new.count)
        var row = old.count
        var column = new.count
        while row > 0 && column > 0 {
            if old[row - 1] == new[column - 1], scores[row][column] == scores[row - 1][column - 1] + 1 {
                oldChanged[row - 1] = false
                newChanged[column - 1] = false
                row -= 1
                column -= 1
            } else if scores[row - 1][column] >= scores[row][column - 1] {
                row -= 1
            } else {
                column -= 1
            }
        }
        return (oldChanged, newChanged)
    }

    private static func prefixSuffixUnmatched(_ old: [String], _ new: [String]) -> (old: [Bool], new: [Bool]) {
        var prefix = 0
        while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix && suffix < new.count - prefix
            && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var oldChanged = Array(repeating: false, count: old.count)
        var newChanged = Array(repeating: false, count: new.count)
        if old.count > prefix + suffix {
            for index in prefix..<(old.count - suffix) { oldChanged[index] = true }
        }
        if new.count > prefix + suffix {
            for index in prefix..<(new.count - suffix) { newChanged[index] = true }
        }
        return (oldChanged, newChanged)
    }

    private static func ranges(_ tokens: [LineToken], changed: [Bool]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var index = 0
        while index < tokens.count {
            guard changed[index] else { index += 1; continue }
            let start = tokens[index].range.lowerBound
            var end = tokens[index].range.upperBound
            index += 1
            while index < tokens.count && changed[index] {
                end = tokens[index].range.upperBound
                index += 1
            }
            result.append(start..<end)
        }
        return result
    }

    public static func sideBySide(_ hunk: GitHunk) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var i = 0
        let lines = hunk.lines
        while i < lines.count {
            switch lines[i].kind {
            case .context:
                rows.append(SideBySideRow(left: lines[i], right: lines[i]))
                i += 1
            case .removed:
                var removals: [GitDiffLine] = []
                var additions: [GitDiffLine] = []
                while i < lines.count && lines[i].kind == .removed { removals.append(lines[i]); i += 1 }
                while i < lines.count && lines[i].kind == .added { additions.append(lines[i]); i += 1 }
                for j in 0..<max(removals.count, additions.count) {
                    rows.append(SideBySideRow(
                        left: j < removals.count ? removals[j] : nil,
                        right: j < additions.count ? additions[j] : nil
                    ))
                }
            case .added:
                rows.append(SideBySideRow(left: nil, right: lines[i]))
                i += 1
            }
        }
        return rows
    }
}
