import Foundation
import Observation

nonisolated struct ShortcutSuggestion: Equatable, Sendable {
    let kind: ShortcutKind
    let value: String
    let draft: Shortcut

    var identifier: String { ShortcutStats.identifier(kind, value) }
}

nonisolated struct ShortcutStats: Codable, Equatable, Sendable {
    static let capacity = 200
    static let minimumCommandLength = 20
    static let commandThreshold = 4
    static let directoryThreshold = 5

    var directories: [String: Int] = [:]
    var commands: [String: Int] = [:]
    var dismissed: [String] = []
    var lastDirectory: String?

    static func identifier(_ kind: ShortcutKind, _ value: String) -> String {
        kind.rawValue + ":" + value
    }

    static func normalized(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func recordVisit(_ directory: String) {
        guard !directory.isEmpty, directory != lastDirectory else { return }
        lastDirectory = directory
        directories[directory, default: 0] += 1
        Self.trim(&directories)
    }

    static func isTrackable(_ text: String) -> Bool {
        guard text.count >= minimumCommandLength, let first = text.first, ShortcutKind(sigil: first) == nil else { return false }
        let program = text.prefix { !$0.isWhitespace }
        return !["cd", "pushd", "popd"].contains(program)
    }

    mutating func recordCommand(_ command: String) {
        let text = Self.normalized(command)
        guard Self.isTrackable(text) else { return }
        commands[text, default: 0] += 1
        Self.trim(&commands)
    }

    mutating func dismiss(_ suggestion: ShortcutSuggestion) {
        let id = suggestion.identifier
        guard !dismissed.contains(id) else { return }
        dismissed.append(id)
        if dismissed.count > Self.capacity { dismissed.removeFirst(dismissed.count - Self.capacity) }
    }

    func suggestion(
        currentDirectory: String, lastCommand: String?, shortcuts: [Shortcut], home: String = NSHomeDirectory()
    ) -> ShortcutSuggestion? {
        if let lastCommand {
            let command = Self.normalized(lastCommand)
            let taken = shortcuts.contains { $0.kind == .command && Self.normalized($0.value) == command }
            if Self.isTrackable(command), (commands[command] ?? 0) >= Self.commandThreshold, !taken,
               !dismissed.contains(Self.identifier(.command, command)) {
                let draft = Shortcut(
                    kind: .command,
                    key: ShortcutSuggestions.commandKey(for: command, in: shortcuts),
                    name: ShortcutSuggestions.commandWords(command).joined(separator: " "),
                    value: command
                )
                return ShortcutSuggestion(kind: .command, value: command, draft: draft)
            }
        }
        let path = currentDirectory
        let isRoot = path.isEmpty || path == "/" || Self.trimmedSlash(path) == Self.trimmedSlash(home)
        let taken = shortcuts.contains { $0.kind == .directory && $0.value == path }
        guard !isRoot, !taken, (directories[path] ?? 0) >= Self.directoryThreshold,
              !dismissed.contains(Self.identifier(.directory, path))
        else { return nil }
        let folder = (path as NSString).lastPathComponent
        let draft = Shortcut(
            kind: .directory, key: ShortcutSuggestions.directoryKey(for: folder, in: shortcuts), name: folder, value: path
        )
        return ShortcutSuggestion(kind: .directory, value: path, draft: draft)
    }

    private static func trimmedSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func trim(_ counts: inout [String: Int]) {
        guard counts.count > capacity else { return }
        let doomed = counts.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .prefix(counts.count - capacity)
        for entry in doomed { counts[entry.key] = nil }
    }
}

nonisolated enum ShortcutSuggestions {
    private static let wrappers: Set<String> = ["sudo", "env", "time", "nohup", "exec", "command", "caffeinate", "noglob"]
    private static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun", "npx", "bunx", "uv", "poetry", "pipenv", "mise"]
    private static let runVerbs: Set<String> = ["run", "exec", "x", "run-script"]
    private static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "bash", "sh", "zsh", "deno", "perl", "php"]
    private static let scriptExtensions: Set<String> = ["py", "js", "mjs", "cjs", "ts", "rb", "sh", "zsh", "bash", "pl", "php"]

    static func commandKey(for command: String, in shortcuts: [Shortcut]) -> String {
        let base = commandWords(command).joined(separator: "-")
        return unique(base.isEmpty ? "command" : base, kind: .command, in: shortcuts)
    }

    static func commandWords(_ command: String) -> [String] {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let first = words.first, wrappers.contains(first) || isAssignment(first) { words.removeFirst() }
        guard let head = words.popFirst() else { return [] }
        var program = Shortcuts.sanitize((head as NSString).lastPathComponent).lowercased()
        if interpreters.contains(program), let script = words.first, let stem = scriptStem(script) {
            program = stem
            words.removeFirst()
        }
        guard !program.isEmpty else { return [] }
        var parts = [program]
        for word in words {
            if parts.count == 1, runners.contains(program), runVerbs.contains(word) { continue }
            guard parts.count < 2, let part = argumentWord(word) else { break }
            parts.append(part)
        }
        return parts
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func scriptStem(_ word: String) -> String? {
        let name = (word as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard scriptExtensions.contains(ext) else { return nil }
        let stem = Shortcuts.sanitize((name as NSString).deletingPathExtension).lowercased()
        return stem.isEmpty ? nil : stem
    }

    private static func argumentWord(_ word: String) -> String? {
        guard word.count <= 20, let first = word.first, first.isLetter,
              word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":") })
        else { return nil }
        return word.replacingOccurrences(of: ":", with: "-").lowercased()
    }

    static func directoryKey(for folder: String, in shortcuts: [Shortcut]) -> String {
        let base = Shortcuts.sanitize(folder).lowercased()
        return unique(base.isEmpty ? "folder" : base, kind: .directory, in: shortcuts)
    }

    static func unique(_ base: String, kind: ShortcutKind, in shortcuts: [Shortcut]) -> String {
        guard Shortcuts.find(base, kind: kind, in: shortcuts) != nil else { return base }
        var number = 2
        while Shortcuts.find(base + String(number), kind: kind, in: shortcuts) != nil { number += 1 }
        return base + String(number)
    }
}

@Observable
final class ShortcutSuggestionTracker {
    static let shared = ShortcutSuggestionTracker()
    static let defaultsKey = "turm.shortcutStats"
    static let enabledKey = "turm.shortcutSuggestions"

    private(set) var stats: ShortcutStats
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stats = Self.load(from: defaults)
    }

    func recordVisit(_ directory: String) {
        update { $0.recordVisit(directory) }
    }

    func recordCommand(_ command: String) {
        update { $0.recordCommand(command) }
    }

    func dismiss(_ suggestion: ShortcutSuggestion) {
        update { $0.dismiss(suggestion) }
    }

    func suggestion(
        currentDirectory: String, lastCommand: String?, shortcuts: [Shortcut], home: String = NSHomeDirectory()
    ) -> ShortcutSuggestion? {
        stats.suggestion(currentDirectory: currentDirectory, lastCommand: lastCommand, shortcuts: shortcuts, home: home)
    }

    private func update(_ change: (inout ShortcutStats) -> Void) {
        var next = stats
        change(&next)
        guard next != stats else { return }
        stats = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> ShortcutStats {
        guard let data = defaults.string(forKey: defaultsKey)?.data(using: .utf8),
              let stats = try? JSONDecoder().decode(ShortcutStats.self, from: data)
        else { return ShortcutStats() }
        return stats
    }
}
