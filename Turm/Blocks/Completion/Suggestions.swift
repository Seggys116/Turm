import Foundation

nonisolated enum GhostStep {
    private struct Scan {
        var separator: [Bool] = []
        var literal: [Bool] = []
    }

    static func next(text: String, ghost: String, directory: String, env: CompletionEnvironment) -> String {
        let chars = Array(text + ghost)
        let split = text.count
        guard !ghost.isEmpty, chars.count == split + ghost.count else { return ghost }
        let scan = scan(chars)

        var position = split
        while position < chars.count, scan.separator[position] { position += 1 }
        guard position < chars.count else { return ghost }
        var start = position
        if position == split {
            while start > 0, !scan.separator[start - 1] { start -= 1 }
        }
        var end = position
        while end < chars.count, !scan.separator[end] { end += 1 }

        func value(_ range: Range<Int>) -> String {
            String(range.filter { scan.literal[$0] }.map { chars[$0] })
        }
        func step(to stop: Int) -> String {
            String(chars[split..<stop])
        }
        func folderPath(_ folder: String) -> String {
            folder.isEmpty ? directory : env.resolve(path: folder, directory: directory)
        }

        var pathStart = start
        if chars[start] == "-", let equals = (start..<end).first(where: { chars[$0] == "=" && scan.literal[$0] }) {
            if equals >= split { return step(to: equals + 1) }
            pathStart = equals + 1
        }
        guard pathStart < end else { return step(to: end) }

        let slashes = (pathStart..<end).filter { chars[$0] == "/" && scan.literal[$0] }
        if let slash = slashes.first(where: { $0 >= split }) {
            let folder = value(pathStart..<(slash + 1))
            return env.directoryEntries(atPath: folderPath(folder)) != nil ? step(to: slash + 1) : step(to: end)
        }

        let componentStart = slashes.last.map { $0 + 1 } ?? pathStart
        let name = value(componentStart..<end)
        if let dot = name.lastIndex(of: "."), dot > name.startIndex,
           let entries = env.directoryEntries(atPath: folderPath(value(pathStart..<componentStart))),
           entries.contains(where: { $0.name == name && !$0.isDirectory }) {
            let stem = String(name[..<dot])
            if entries.contains(where: { $0.name != name && $0.name.hasPrefix(stem) }) {
                var counted = 0
                var stop = componentStart
                while stop < end, counted < stem.count {
                    if scan.literal[stop] { counted += 1 }
                    stop += 1
                }
                if stop > split { return step(to: stop) }
            }
        }
        return step(to: end)
    }

    private static func scan(_ chars: [Character]) -> Scan {
        var result = Scan()
        var single = false
        var double = false
        var escaped = false
        for character in chars {
            var separator = false
            var literal = true
            if escaped {
                escaped = false
            } else if single {
                if character == "'" { single = false; literal = false }
            } else if character == "\\" {
                escaped = true
                literal = false
            } else if double {
                if character == "\"" { double = false; literal = false }
            } else if character == "'" {
                single = true
                literal = false
            } else if character == "\"" {
                double = true
                literal = false
            } else if character.isWhitespace {
                separator = true
                literal = false
            }
            result.separator.append(separator)
            result.literal.append(literal)
        }
        return result
    }
}

nonisolated enum SuggestionList {
    static let historyLimit = 6

    static func merge(
        text: String, range: NSRange?, items: [CompletionItem], history: [String]
    ) -> (range: NSRange, items: [CompletionItem]) {
        let length = (text as NSString).length
        let range = range ?? NSRange(location: length, length: 0)
        guard NSMaxRange(range) == length else { return (range, items) }
        let typed = (text as NSString).substring(with: range)
        let suggestions = CommandHistory.suggestions(for: text, in: history, limit: historyLimit)
        var seen = Set(suggestions)
        var merged = suggestions.map {
            CompletionItem(insert: typed + $0, display: text + $0, kind: .history, terminator: "")
        }
        for item in items {
            if let suffix = ghost(for: item, typed: typed), !seen.insert(suffix).inserted { continue }
            merged.append(item)
        }
        return (range, merged)
    }

    static func ghost(for item: CompletionItem, typed: String) -> String? {
        guard item.insert.count > typed.count, item.insert.hasPrefix(typed) else { return nil }
        return String(item.insert.dropFirst(typed.count))
    }

    static func sole(_ items: [CompletionItem]) -> CompletionItem? {
        let candidates = items.filter { $0.kind != .history }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func extends(_ result: CompletionResult?, line: String) -> Bool {
        guard let result else { return false }
        let typed = String(line[result.range])
        return result.items.contains { ghost(for: $0, typed: typed) != nil }
    }
}
