import Foundation

final class CommandHistory {
    static let shared = CommandHistory()

    private(set) var entries: [String]
    private let limit = 2000

    init(entries: [String]? = nil) {
        self.entries = entries ?? Self.loadZshHistory()
    }

    func record(_ command: String) {
        entries.removeAll { $0 == command }
        entries.append(command)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func suggestion(for text: String) -> String? {
        Self.suggestion(for: text, in: entries)
    }

    nonisolated static func suggestion(for text: String, in entries: [String]) -> String? {
        suggestions(for: text, in: entries, limit: 1).first
    }

    nonisolated static func suggestions(for text: String, in entries: [String], limit: Int) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        var results: [String] = []
        var seen = Set<String>()
        for entry in entries.reversed() where entry.count > text.count && entry.hasPrefix(text) {
            let rest = String(entry.dropFirst(text.count))
            guard !rest.contains("\n"), seen.insert(rest).inserted else { continue }
            results.append(rest)
            if results.count == limit { break }
        }
        return results
    }

    static func parseZsh(_ text: String) -> [String] {
        var commands: [String] = []
        var pending: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var body = String(line)
            if let current = pending {
                body = current + "\n" + body
                pending = nil
            } else if body.hasPrefix(": "), let semicolon = body.firstIndex(of: ";") {
                body = String(body[body.index(after: semicolon)...])
            }
            if body.hasSuffix("\\") {
                pending = String(body.dropLast())
                continue
            }
            if !body.isEmpty { commands.append(body) }
        }
        var seen = Set<String>()
        var unique: [String] = []
        for command in commands.reversed() where seen.insert(command).inserted {
            unique.append(command)
        }
        return unique.reversed()
    }

    private static func loadZshHistory() -> [String] {
        let path = ProcessInfo.processInfo.environment["HISTFILE"]
            ?? (ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()) + "/.zsh_history"
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let parsed = parseZsh(text)
        return Array(parsed.suffix(2000))
    }
}
