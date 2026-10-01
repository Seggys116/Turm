import Foundation
import Observation

public nonisolated enum ShortcutKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case directory
    case command
    case file

    public var id: Self { self }

    public var sigil: Character {
        switch self {
        case .directory: "@"
        case .command: "!"
        case .file: "#"
        }
    }

    public init?(sigil: Character) {
        guard let kind = Self.allCases.first(where: { $0.sigil == sigil }) else { return nil }
        self = kind
    }

    public var title: String {
        switch self {
        case .directory: "Directory"
        case .command: "Command"
        case .file: "File"
        }
    }

    public var symbol: String {
        switch self {
        case .directory: "folder"
        case .command: "terminal"
        case .file: "doc"
        }
    }

    public var allowsSubpath: Bool { self == .directory }
}

public nonisolated struct Shortcut: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ShortcutKind
    public var key: String
    public var name: String
    public var value: String
    public var projectRoot: String?
    public var modified: Date?

    public init(
        id: UUID = UUID(), kind: ShortcutKind, key: String, name: String, value: String, projectRoot: String? = nil,
        modified: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.name = name
        self.value = value
        self.projectRoot = projectRoot
        self.modified = modified
    }

    public var token: String { String(kind.sigil) + key }

    public var isProject: Bool { projectRoot != nil }

    public func isMissing(_ exists: (String) -> Bool) -> Bool {
        kind != .command && !exists(value)
    }

    public var placeholders: (highest: Int, all: Bool) {
        var highest = 0
        var all = false
        var rest = value[...]
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else { break }
            let inner = after[..<close]
            if inner == "@" { all = true } else if let number = Int(inner), number > 0 { highest = max(highest, number) }
            rest = after[after.index(after: close)...]
        }
        return (highest, all)
    }

    public var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key : trimmed
    }
}

public nonisolated struct ShortcutMatch: Equatable, Sendable {
    public let shortcut: Shortcut
    public let subpath: String
    public let range: Range<String.Index>
    public let isLead: Bool

    public init(shortcut: Shortcut, subpath: String, range: Range<String.Index>, isLead: Bool) {
        self.shortcut = shortcut
        self.subpath = subpath
        self.range = range
        self.isLead = isLead
    }

    public var target: String {
        guard shortcut.kind != .command, !subpath.isEmpty else { return shortcut.value }
        return (shortcut.value as NSString).appendingPathComponent(subpath)
    }

    public var changesDirectory: Bool { isLead && shortcut.kind == .directory }
}

public nonisolated struct ShortcutReplacement: Equatable, Sendable {
    public let match: ShortcutMatch
    public let range: Range<String.Index>
    public let text: String

    public init(match: ShortcutMatch, range: Range<String.Index>, text: String) {
        self.match = match
        self.range = range
        self.text = text
    }
}

public nonisolated struct ShortcutLaunch: Equatable, Sendable {
    public let directory: String?
    public let command: String

    public init(directory: String?, command: String) {
        self.directory = directory
        self.command = command
    }
}

public nonisolated struct ShortcutPartial: Equatable, Sendable {
    public let kind: ShortcutKind
    public let key: String
    public let subpath: String?
    public let range: Range<String.Index>

    public init(kind: ShortcutKind, key: String, subpath: String?, range: Range<String.Index>) {
        self.kind = kind
        self.key = key
        self.subpath = subpath
        self.range = range
    }
}

public nonisolated enum Shortcuts {
    public static let key = "turm.shortcuts"
    public static let legacyKey = "turm.knownDirs"
    public static let boundaries: Set<Character> = [";", "|", "&", "(", ")", "<", ">"]

    public static func load(from defaults: UserDefaults = .standard) -> [Shortcut] {
        if let data = defaults.string(forKey: key)?.data(using: .utf8) {
            return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
        }
        guard let data = defaults.string(forKey: legacyKey)?.data(using: .utf8),
              let legacy = try? JSONDecoder().decode([LegacyDirectory].self, from: data)
        else { return [] }
        return legacy.map { Shortcut(kind: .directory, key: $0.key, name: $0.name, value: $0.path) }
    }

    public static func save(_ shortcuts: [Shortcut], to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(shortcuts) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    public static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, ShortcutKind(sigil: first) != nil { text.removeFirst() }
        return String(text.filter(isKeyCharacter))
    }

    public static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
    }

    public static func find(_ key: String, kind: ShortcutKind, in shortcuts: [Shortcut]) -> Shortcut? {
        shortcuts.first { $0.kind == kind && $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    public static func conflict(for key: String, kind: ShortcutKind, excluding id: UUID?, in shortcuts: [Shortcut]) -> Shortcut? {
        guard let existing = find(key, kind: kind, in: shortcuts), existing.id != id else { return nil }
        return existing
    }

    public static func match(path: String, in shortcuts: [Shortcut]) -> (shortcut: Shortcut, rest: String)? {
        var best: (shortcut: Shortcut, rest: String)?
        for shortcut in shortcuts where shortcut.kind == .directory {
            let root = shortcut.value
            let rest: String
            if path == root {
                rest = ""
            } else if path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
                rest = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                continue
            }
            if best.map({ root.count > $0.shortcut.value.count }) ?? true { best = (shortcut, rest) }
        }
        return best
    }

    public static func scan(_ line: String, in shortcuts: [Shortcut]) -> [ShortcutMatch] {
        guard !shortcuts.isEmpty else { return [] }
        var matches: [ShortcutMatch] = []
        walkTokens(line) { range in
            guard let found = resolve(line[range], in: shortcuts) else { return false }
            let isLead = line[..<range.lowerBound].allSatisfy(\.isWhitespace)
            matches.append(ShortcutMatch(shortcut: found.shortcut, subpath: found.subpath, range: range, isLead: isLead))
            return true
        }
        return matches
    }

    public static func unknown(_ line: String, in shortcuts: [Shortcut]) -> [(key: String, range: Range<String.Index>)] {
        var unknown: [(key: String, range: Range<String.Index>)] = []
        walkTokens(line) { range in
            let token = line[range]
            if resolve(token, in: shortcuts) != nil { return true }
            let key = token.dropFirst()
            guard token.first == ShortcutKind.directory.sigil, !key.isEmpty, key.allSatisfy(isKeyCharacter) else { return false }
            unknown.append((String(key), range))
            return true
        }
        return unknown
    }

    private static func walkTokens(_ line: String, _ visit: (Range<String.Index>) -> Bool) {
        var quote: Character?
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if ShortcutKind(sigil: character) != nil, startsWord(line, at: index) {
                let end = tokenEnd(line, from: index)
                if visit(index..<end) {
                    index = end
                    continue
                }
            }
            index = line.index(after: index)
        }
    }

    public static func partial(atEndOf prefix: String) -> ShortcutPartial? {
        var quote: Character?
        var escaped = false
        var start = prefix.startIndex
        var index = prefix.startIndex
        while index < prefix.endIndex {
            let character = prefix[index]
            let next = prefix.index(after: index)
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace || boundaries.contains(character) || character == "=" {
                start = next
            }
            index = next
        }
        guard quote == nil, !escaped, start < prefix.endIndex, let kind = ShortcutKind(sigil: prefix[start]) else { return nil }
        let body = prefix[prefix.index(after: start)...]
        let key = body.prefix(while: isKeyCharacter)
        let rest = body.dropFirst(key.count)
        if rest.isEmpty { return ShortcutPartial(kind: kind, key: String(key), subpath: nil, range: start..<prefix.endIndex) }
        guard kind.allowsSubpath, !key.isEmpty, rest.first == "/" else { return nil }
        return ShortcutPartial(kind: kind, key: String(key), subpath: String(rest.dropFirst()), range: start..<prefix.endIndex)
    }

    public static func expand(_ line: String, in shortcuts: [Shortcut], quote: (String) -> String) -> String? {
        let replacements = replacements(in: line, shortcuts: shortcuts, quote: quote)
        return replacements.isEmpty ? nil : apply(replacements, to: line)
    }

    public static func apply(_ replacements: [ShortcutReplacement], to line: String) -> String {
        var output = ""
        var cursor = line.startIndex
        for replacement in replacements {
            output += line[cursor..<replacement.range.lowerBound]
            output += replacement.text
            cursor = replacement.range.upperBound
        }
        output += line[cursor...]
        return output
    }

    public static func replacements(
        in line: String, shortcuts: [Shortcut], quote: (String) -> String, allowLead: Bool = true
    ) -> [ShortcutReplacement] {
        let matches = scan(line, in: shortcuts).map { match in
            allowLead ? match : ShortcutMatch(shortcut: match.shortcut, subpath: match.subpath, range: match.range, isLead: false)
        }
        guard !matches.isEmpty else { return [] }
        let pieces = argumentPieces(in: line, matches: matches)
        var result: [ShortcutReplacement] = []
        var consumedUntil = line.startIndex
        for match in matches where match.range.lowerBound >= consumedUntil {
            var range = match.range
            let text: String
            switch match.shortcut.kind {
            case .command:
                let wanted = match.shortcut.placeholders
                let segment = pieces.filter { $0.range.lowerBound >= match.range.upperBound }.prefix(while: \.isWord).map(\.range)
                let used = wanted.all ? Array(segment) : Array(segment.prefix(wanted.highest))
                let arguments = used.map { word -> String in
                    let raw = String(line[word])
                    let inner = replacements(in: raw, shortcuts: shortcuts, quote: quote, allowLead: false)
                    return inner.isEmpty ? raw : apply(inner, to: raw)
                }
                text = fill(match.shortcut.value, arguments: arguments)
                if let last = used.last { range = match.range.lowerBound..<last.upperBound }
            case .file:
                text = quote(match.target)
            case .directory where match.changesDirectory:
                let next = line[match.range.upperBound...].first { !$0.isWhitespace }
                text = "cd " + quote(match.target) + (next.map { boundaries.contains($0) ? "" : " &&" } ?? "")
            case .directory:
                text = quote(match.target)
            }
            result.append(ShortcutReplacement(match: match, range: range, text: text))
            consumedUntil = range.upperBound
        }
        return result
    }

    public static func fill(_ template: String, arguments: [String]) -> String {
        var output = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else { break }
            let inner = after[..<close]
            output += rest[..<open]
            if inner == "@" {
                output += arguments.joined(separator: " ")
            } else if let number = Int(inner), number > 0 {
                if number <= arguments.count { output += arguments[number - 1] }
            } else {
                output += rest[open...close]
            }
            rest = after[after.index(after: close)...]
        }
        output += rest
        return output.trimmingCharacters(in: .whitespaces)
    }

    public static func launch(_ line: String, in shortcuts: [Shortcut]) -> ShortcutLaunch {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lead = scan(trimmed, in: shortcuts).first, lead.changesDirectory else {
            return ShortcutLaunch(directory: nil, command: trimmed)
        }
        var rest = trimmed[lead.range.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.first == ";" || rest.hasPrefix("&&") {
            rest = String(rest.drop(while: { $0 == ";" || $0 == "&" })).trimmingCharacters(in: .whitespaces)
        }
        return ShortcutLaunch(directory: lead.target, command: rest)
    }

    public static func merged(_ global: [Shortcut], project: [Shortcut]) -> [Shortcut] {
        guard !project.isEmpty else { return global }
        return project + global.filter { entry in find(entry.key, kind: entry.kind, in: project) == nil }
    }

    public static func project(_ entries: [String: String], root: String, home: String = NSHomeDirectory()) -> (shortcuts: [Shortcut], invalid: [String]) {
        var shortcuts: [Shortcut] = []
        var invalid: [String] = []
        for (token, value) in entries.sorted(by: { $0.key < $1.key }) {
            guard let sigil = token.first, let kind = ShortcutKind(sigil: sigil),
                  case let key = String(token.dropFirst()), !key.isEmpty, key.allSatisfy(isKeyCharacter),
                  !value.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                invalid.append(token)
                continue
            }
            let resolved: String
            if kind == .command {
                resolved = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value == "~" {
                resolved = home
            } else if value.hasPrefix("~/") {
                resolved = home + value.dropFirst()
            } else if value.hasPrefix("/") {
                resolved = value
            } else {
                resolved = URL(fileURLWithPath: root).appendingPathComponent(value).standardizedFileURL.path
            }
            shortcuts.append(Shortcut(kind: kind, key: key, name: "", value: resolved, projectRoot: root))
        }
        return (shortcuts, invalid)
    }

    private static func argumentPieces(in line: String, matches: [ShortcutMatch]) -> [(range: Range<String.Index>, isWord: Bool)] {
        let masked = masked(line, matches: matches.map {
            ShortcutMatch(shortcut: $0.shortcut, subpath: $0.subpath, range: $0.range, isLead: false)
        })
        return ShellTokenizer.tokenize(masked).map { token in
            let lower = masked.utf16.distance(from: masked.startIndex, to: token.range.lowerBound)
            let upper = masked.utf16.distance(from: masked.startIndex, to: token.range.upperBound)
            let range = String.Index(utf16Offset: lower, in: line)..<String.Index(utf16Offset: upper, in: line)
            return (range, token.kind == .word)
        }
    }

    public static func masked(_ line: String, matches: [ShortcutMatch]) -> String {
        guard !matches.isEmpty else { return line }
        var output = ""
        var cursor = line.startIndex
        for match in matches {
            output += line[cursor..<match.range.lowerBound]
            let width = line[match.range].utf16.count
            output += String(repeating: match.changesDirectory ? " " : "_", count: width)
            cursor = match.range.upperBound
        }
        output += line[cursor...]
        return output
    }

    private static func startsWord(_ line: String, at index: String.Index) -> Bool {
        guard index > line.startIndex else { return true }
        let previous = line[line.index(before: index)]
        return previous.isWhitespace || boundaries.contains(previous) || previous == "="
    }

    private static func tokenEnd(_ line: String, from start: String.Index) -> String.Index {
        var index = line.index(after: start)
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace || boundaries.contains(character) || character == "'" || character == "\"" || character == "\\" { break }
            index = line.index(after: index)
        }
        return index
    }

    private static func resolve(_ token: Substring, in shortcuts: [Shortcut]) -> (shortcut: Shortcut, subpath: String)? {
        guard let sigil = token.first, let kind = ShortcutKind(sigil: sigil) else { return nil }
        let body = token.dropFirst()
        let key = body.prefix(while: isKeyCharacter)
        guard !key.isEmpty, let shortcut = find(String(key), kind: kind, in: shortcuts) else { return nil }
        let rest = body.dropFirst(key.count)
        if rest.isEmpty { return (shortcut, "") }
        guard kind.allowsSubpath, rest.first == "/" else { return nil }
        return (shortcut, String(rest.drop(while: { $0 == "/" })))
    }

    private struct LegacyDirectory: Decodable {
        let key: String
        let name: String
        let path: String
    }
}

public nonisolated final class ProjectShortcutIndex: @unchecked Sendable {
    public static let shared = ProjectShortcutIndex()

    private let lock = NSLock()
    private var byDirectory: [String: [Shortcut]] = [:]

    public init() {}

    public func set(_ shortcuts: [Shortcut], for directory: String) {
        lock.lock()
        defer { lock.unlock() }
        byDirectory[directory] = shortcuts.isEmpty ? nil : shortcuts
    }

    public func shortcuts(for directory: String) -> [Shortcut] {
        lock.lock()
        defer { lock.unlock() }
        return byDirectory[directory] ?? []
    }
}

@Observable
public final class ShortcutStore {
    public static let shared = ShortcutStore()

    public private(set) var items: [Shortcut]
    @ObservationIgnored public var onChange: ((RecordChange<Shortcut>) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Shortcuts.load(from: defaults)
    }

    public func effective(in directory: String) -> [Shortcut] {
        Shortcuts.merged(items, project: ProjectShortcutIndex.shared.shortcuts(for: directory))
    }

    public func items(of kind: ShortcutKind) -> [Shortcut] {
        items.filter { $0.kind == kind }
    }

    public func directory(at path: String) -> Shortcut? {
        items.first { $0.kind == .directory && $0.value == path }
    }

    public func label(for path: String) -> String {
        guard let match = Shortcuts.match(path: path, in: items) else { return PathDisplay.abbreviate(path) }
        return match.rest.isEmpty ? match.shortcut.label : match.shortcut.label + "/" + match.rest
    }

    @discardableResult
    public func save(_ shortcut: Shortcut) -> Bool {
        var entry = shortcut
        entry.key = Shortcuts.sanitize(shortcut.key)
        entry.name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.kind == .command { entry.value = shortcut.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !entry.key.isEmpty, !entry.value.isEmpty,
              Shortcuts.conflict(for: entry.key, kind: entry.kind, excluding: entry.id, in: items) == nil
        else { return false }
        entry.modified = Date()
        if let index = items.firstIndex(where: { $0.id == entry.id }) {
            items[index] = entry
        } else {
            items.append(entry)
        }
        persist()
        onChange?(.saved(entry))
        return true
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
        onChange?(.removed(id))
    }

    // applied without reporting back, so remote records do not echo to the cloud
    public func applyRemote(_ incoming: [Shortcut], removing removed: [UUID]) {
        guard !incoming.isEmpty || !removed.isEmpty else { return }
        items.removeAll { removed.contains($0.id) }
        for received in incoming {
            var shortcut = received
            shortcut.key = Shortcuts.sanitize(received.key)
            guard !shortcut.key.isEmpty, !shortcut.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var number = 2
            let base = shortcut.key
            while Shortcuts.conflict(for: shortcut.key, kind: shortcut.kind, excluding: shortcut.id, in: items) != nil {
                shortcut.key = base + String(number)
                number += 1
            }
            if let index = items.firstIndex(where: { $0.id == shortcut.id }) {
                items[index] = shortcut
            } else {
                items.append(shortcut)
            }
        }
        persist()
    }

    private func persist() {
        Shortcuts.save(items, to: defaults)
        NotificationCenter.default.post(name: .completionEnvironmentChanged, object: nil)
    }
}
