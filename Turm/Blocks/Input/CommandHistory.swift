import Foundation

nonisolated struct HistoryEntry: Codable, Equatable, Sendable {
    let command: String
    let directory: String?
}

nonisolated enum HistoryShell: Equatable, Sendable {
    case zsh
    case bash
    case fish

    static func detect(environment: [String: String]) -> HistoryShell {
        let name = (environment["SHELL"] ?? "").split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "bash": return .bash
        case "fish": return .fish
        default: return .zsh
        }
    }

    func historyPath(environment: [String: String], home: String) -> String {
        switch self {
        case .zsh:
            return environment["HISTFILE"] ?? (environment["ZDOTDIR"] ?? home) + "/.zsh_history"
        case .bash:
            return environment["HISTFILE"] ?? home + "/.bash_history"
        case .fish:
            let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
            return data + "/fish/fish_history"
        }
    }
}

nonisolated enum HistoryStore {
    // Serial so a late debounced write can never overtake a newer one.
    static let queue = DispatchQueue(label: "turm.history.write", qos: .utility)

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Turm", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    static func load(_ url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return decoded
    }

    static func write(_ entries: [HistoryEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

final class CommandHistory {
    static let shared = CommandHistory(
        entries: nil,
        store: WorkspacePersistence.isRunningTests ? nil : HistoryStore.defaultURL
    )

    nonisolated static let limit = 2000
    nonisolated static let saveDelay: TimeInterval = 0.5

    // Oldest first, unique per command and directory.
    private(set) var items: [HistoryEntry]
    // Unique commands, oldest first, most recent run last.
    private(set) var entries: [String]
    private let store: URL?
    private var pendingSave: DispatchWorkItem?

    // `entries` nil loads the user's shell history file; `store` is where Turm's directory-tagged entries persist.
    convenience init(entries: [String]? = nil, store: URL? = nil) {
        self.init(items: nil, commands: entries, store: store)
    }

    convenience init(items: [HistoryEntry], store: URL? = nil) {
        self.init(items: items, commands: nil, store: store)
    }

    private init(items: [HistoryEntry]?, commands: [String]?, store: URL?) {
        self.store = store
        if let items {
            self.items = Array(Self.deduplicated(items).suffix(Self.limit))
        } else {
            let base = commands ?? Self.loadShellHistory()
            let persisted = store.map(HistoryStore.load) ?? []
            self.items = Self.merge(base: base, persisted: persisted)
        }
        entries = Self.commands(of: self.items)
    }

    func restore(_ commands: [String]) {
        items = Array(commands.suffix(Self.limit)).map { HistoryEntry(command: $0, directory: nil) }
        entries = Self.commands(of: items)
    }

    func record(_ command: String, directory: String? = nil) {
        items.removeAll { $0.command == command && $0.directory == directory }
        items.append(HistoryEntry(command: command, directory: directory))
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        entries = Self.commands(of: items)
        if directory != nil { scheduleSave() }
    }

    // Writes any pending entries now; the debounce otherwise drops them if the app quits first.
    func flush() {
        guard let store else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = persistedItems()
        HistoryStore.queue.sync { HistoryStore.write(snapshot, to: store) }
    }

    func suggestion(for text: String) -> String? {
        Self.suggestion(for: text, in: entries)
    }

    func suggestion(for text: String, directory: String, environment: CompletionEnvironment) -> String? {
        HistorySuggester.suggestion(for: text, in: items, directory: directory, environment: environment)
    }

    private func persistedItems() -> [HistoryEntry] {
        items.filter { $0.directory != nil }
    }

    private func scheduleSave() {
        guard let store else { return }
        pendingSave?.cancel()
        let snapshot = persistedItems()
        let work = DispatchWorkItem { HistoryStore.write(snapshot, to: store) }
        pendingSave = work
        HistoryStore.queue.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
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

    nonisolated static func commands(of items: [HistoryEntry]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for item in items.reversed() where seen.insert(item.command).inserted {
            unique.append(item.command)
        }
        return unique.reversed()
    }

    nonisolated static func deduplicated(_ items: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<HistoryKey>()
        var unique: [HistoryEntry] = []
        for item in items.reversed() where seen.insert(HistoryKey(command: item.command, directory: item.directory)).inserted {
            unique.append(item)
        }
        return unique.reversed()
    }

    // Shell-file commands first, then Turm's own entries; a command Turm recorded replaces its untagged copy.
    nonisolated static func merge(base: [String], persisted: [HistoryEntry]) -> [HistoryEntry] {
        let tagged = Set(persisted.map(\.command))
        let untagged = base.filter { !tagged.contains($0) }.map { HistoryEntry(command: $0, directory: nil) }
        return Array(deduplicated(untagged + persisted).suffix(limit))
    }

    nonisolated static func parseZsh(_ text: String) -> [String] {
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
        return uniqueKeepingLast(commands)
    }

    nonisolated static func parseBash(_ text: String) -> [String] {
        var commands: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#"), line.count > 1, line.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) { continue }
            commands.append(String(line))
        }
        return uniqueKeepingLast(commands)
    }

    nonisolated static func parseFish(_ text: String) -> [String] {
        let prefix = "- cmd: "
        var commands: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix(prefix) {
            let command = unescapeFish(line.dropFirst(prefix.count))
            if !command.isEmpty { commands.append(command) }
        }
        return uniqueKeepingLast(commands)
    }

    private nonisolated static func unescapeFish(_ text: Substring) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private nonisolated static func uniqueKeepingLast(_ commands: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for command in commands.reversed() where seen.insert(command).inserted {
            unique.append(command)
        }
        return unique.reversed()
    }

    nonisolated static func parse(_ text: String, shell: HistoryShell) -> [String] {
        switch shell {
        case .zsh: return parseZsh(text)
        case .bash: return parseBash(text)
        case .fish: return parseFish(text)
        }
    }

    nonisolated static func loadShellHistory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> [String] {
        let shell = HistoryShell.detect(environment: environment)
        let path = shell.historyPath(environment: environment, home: home)
        guard let data = read(path) else { return [] }
        return Array(parse(String(decoding: data, as: UTF8.self), shell: shell).suffix(limit))
    }
}

private nonisolated struct HistoryKey: Hashable {
    let command: String
    let directory: String?
}
