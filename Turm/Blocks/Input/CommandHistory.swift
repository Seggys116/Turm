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
        guard !text.isEmpty else { return nil }
        for entry in entries.reversed() where entry.count > text.count && entry.hasPrefix(text) {
            let rest = entry.dropFirst(text.count)
            if !rest.contains("\n") { return String(rest) }
        }
        return nil
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
