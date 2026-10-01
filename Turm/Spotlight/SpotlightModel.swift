import Foundation
import TurmCore

nonisolated struct SpotlightRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case newShell
        case run
        case open
        case directory
        case command
        case history
        case shell
        case block
    }

    let kind: Kind
    let id: String
    let title: String
    let detail: String?
    let symbol: String
    let directory: String?
    let command: String?
    let token: String?
    var tab: UUID?
    var pane: PaneID?
}

nonisolated struct SpotlightShell: Sendable {
    let tab: UUID
    let pane: PaneID?
    let title: String
    let detail: String
    let fields: [String]
    let commands: [String]
    let isSettings: Bool
}

nonisolated enum SpotlightModel {
    static let historyLimit = 8
    static let blockLimit = 12
    static let searchSigil: Character = "?"

    static func isSearch(_ query: String) -> Bool {
        query.drop(while: \.isWhitespace).first == searchSigil
    }

    static func searchRows(query: String, shells: [SpotlightShell]) -> [SpotlightRow] {
        let needle = query.drop(while: \.isWhitespace).dropFirst().trimmingCharacters(in: .whitespaces)
        let matched = shells.enumerated().compactMap { offset, shell -> (offset: Int, rank: Int, shell: SpotlightShell)? in
            guard needle.isEmpty || ShellFilter.matches(needle, fields: shell.fields) || rank(needle, in: shell.fields) != nil else { return nil }
            return (offset, rank(needle, in: shell.fields) ?? 3, shell)
        }
        let shellRows = matched.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map { entry in
            SpotlightRow(
                kind: .shell, id: "shell:\(entry.shell.tab)-\(entry.offset)", title: entry.shell.title, detail: entry.shell.detail,
                symbol: entry.shell.isSettings ? "gearshape" : "terminal", directory: nil, command: nil, token: nil,
                tab: entry.shell.tab, pane: entry.shell.pane
            )
        }
        guard !needle.isEmpty else { return shellRows }
        var blocks: [(rank: Int, row: SpotlightRow)] = []
        for (offset, shell) in shells.enumerated() {
            var seen = Set<String>()
            for command in shell.commands.reversed() where seen.insert(command).inserted {
                guard let score = rank(needle, in: [command]) else { continue }
                blocks.append((score, SpotlightRow(
                    kind: .block, id: "block:\(offset):\(command)", title: command, detail: "in " + shell.title,
                    symbol: "text.magnifyingglass", directory: nil, command: command, token: nil,
                    tab: shell.tab, pane: shell.pane
                )))
            }
        }
        let blockRows = blocks.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(blockLimit)
            .map(\.element.row)
        return shellRows + blockRows
    }

    static func rows(
        query: String,
        currentDirectory: String,
        shortcuts: [Shortcut],
        history: [String],
        label: (String) -> String
    ) -> [SpotlightRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let here = label(currentDirectory)
        guard !trimmed.isEmpty else {
            return [newShellRow(here)]
                + directoryRows(shortcuts, needle: "", label: label)
                + commandRows(shortcuts, needle: "", directory: nil)
                + historyRows(history, needle: "", directory: nil)
        }

        let launch = Shortcuts.launch(trimmed, in: shortcuts)
        var result: [SpotlightRow] = []
        if launch.command.isEmpty, let directory = launch.directory {
            result.append(SpotlightRow(
                kind: .open, id: "open", title: "Open \(label(directory))", detail: nil,
                symbol: "folder", directory: directory, command: nil, token: nil
            ))
        } else if !launch.command.isEmpty {
            result.append(SpotlightRow(
                kind: .run, id: "run", title: "Run \(launch.command)", detail: label(launch.directory ?? currentDirectory),
                symbol: "return", directory: launch.directory, command: launch.command, token: nil
            ))
        }

        let needle = launch.directory == nil ? trimmed : launch.command
        guard !needle.isEmpty else { return result }
        return result
            + directoryRows(shortcuts, needle: needle, label: label)
            + commandRows(shortcuts, needle: needle, directory: launch.directory)
            + historyRows(history, needle: needle, directory: launch.directory)
    }

    static func completion(of row: SpotlightRow, query: String) -> String? {
        switch row.kind {
        case .directory, .command:
            guard let token = row.token else { return nil }
            let start = query.lastIndex(where: \.isWhitespace).map { query.index(after: $0) } ?? query.startIndex
            return String(query[..<start]) + token + " "
        case .history:
            return row.command
        case .newShell, .run, .open, .shell, .block:
            return nil
        }
    }

    static func rank(_ needle: String, in fields: [String]) -> Int? {
        let wanted = needle.lowercased()
        guard !wanted.isEmpty else { return 0 }
        var best: Int?
        for field in fields where !field.isEmpty {
            let text = field.lowercased()
            let score: Int
            if text.hasPrefix(wanted) {
                score = 0
            } else if text.contains(wanted) {
                score = 1
            } else if isSubsequence(wanted, of: text) {
                score = 2
            } else {
                continue
            }
            if score < (best ?? Int.max) { best = score }
        }
        return best
    }

    static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var remaining = needle[...]
        for character in text {
            guard let next = remaining.first else { break }
            if character == next { remaining.removeFirst() }
        }
        return remaining.isEmpty
    }

    private static func newShellRow(_ here: String) -> SpotlightRow {
        SpotlightRow(
            kind: .newShell, id: "new", title: "New shell", detail: here,
            symbol: "plus", directory: nil, command: nil, token: nil
        )
    }

    private static func split(_ needle: String) -> (kind: ShortcutKind?, text: String) {
        guard let first = needle.first, let kind = ShortcutKind(sigil: first) else { return (nil, needle) }
        return (kind, String(needle.dropFirst()))
    }

    private static func directoryRows(_ shortcuts: [Shortcut], needle: String, label: (String) -> String) -> [SpotlightRow] {
        ranked(shortcuts, kind: .directory, needle: needle).map { shortcut in
            SpotlightRow(
                kind: .directory, id: "dir:" + shortcut.token, title: shortcut.token, detail: label(shortcut.value),
                symbol: ShortcutKind.directory.symbol, directory: shortcut.value, command: nil, token: shortcut.token
            )
        }
    }

    private static func commandRows(_ shortcuts: [Shortcut], needle: String, directory: String?) -> [SpotlightRow] {
        ranked(shortcuts, kind: .command, needle: needle).map { shortcut in
            SpotlightRow(
                kind: .command, id: "cmd:" + shortcut.token, title: shortcut.token, detail: shortcut.value,
                symbol: ShortcutKind.command.symbol, directory: directory, command: shortcut.token, token: shortcut.token
            )
        }
    }

    private static func ranked(_ shortcuts: [Shortcut], kind: ShortcutKind, needle: String) -> [Shortcut] {
        let parts = split(needle)
        if let narrowed = parts.kind, narrowed != kind { return [] }
        let scored: [(offset: Int, rank: Int, shortcut: Shortcut)] = shortcuts.enumerated().compactMap { offset, shortcut in
            guard shortcut.kind == kind,
                  let rank = rank(parts.text, in: [shortcut.key, shortcut.name, shortcut.value])
            else { return nil }
            return (offset, rank, shortcut)
        }
        return scored.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map(\.shortcut)
    }

    private static func historyRows(_ history: [String], needle: String, directory: String?) -> [SpotlightRow] {
        var seen = Set<String>()
        var scored: [(offset: Int, rank: Int, command: String)] = []
        for command in history.reversed() where seen.insert(command).inserted {
            guard let rank = rank(needle, in: [command]) else { continue }
            scored.append((scored.count, rank, command))
        }
        return scored.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .prefix(historyLimit)
            .map { entry in
                SpotlightRow(
                    kind: .history, id: "hist:" + entry.command, title: entry.command, detail: nil,
                    symbol: "clock", directory: directory, command: entry.command, token: nil
                )
            }
    }
}
