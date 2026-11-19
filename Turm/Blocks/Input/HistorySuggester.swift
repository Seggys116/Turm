import Foundation
import TurmCore

// Picks the ghost-text suffix from history, dropping entries that cannot work where the user is now.
nonisolated enum HistorySuggester {
    static let maxCandidates = 50

    private static let wrappers: Set<String> = ["sudo", "doas", "env", "exec", "command", "time", "nohup", "nice", "builtin"]
    private static let wrapperValueOptions: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"],
        "doas": ["-u", "-C"],
        "nice": ["-n"],
    ]
    // Shell syntax, not commands: lines using it are only judged by their first command.
    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function", "coproc",
    ]
    private static let alwaysAllowed: Set<String> = ["[", "[[", "]]", ".", ":", "!", "{", "}"]
    private static let simpleSeparators: Set<String> = ["|", "&&", "||", "|&", ";"]

    // The most recent valid entry run in `directory` wins; otherwise the most recent valid one anywhere.
    static func suggestion(
        for text: String, in items: [HistoryEntry], directory: String, environment: CompletionEnvironment
    ) -> String? {
        guard !text.isEmpty else { return nil }
        var examined = 0
        var fallback: String?
        for item in items.reversed() {
            let command = item.command
            guard command.count > text.count, command.hasPrefix(text), !command.contains("\n") else { continue }
            let local = item.directory == directory
            if !local, fallback != nil { continue }
            examined += 1
            if isValid(command, directory: directory, environment: environment) {
                if local { return String(command.dropFirst(text.count)) }
                fallback = String(command.dropFirst(text.count))
            }
            if examined >= maxCandidates { break }
        }
        return fallback
    }

    static func isValid(_ command: String, directory: String, environment env: CompletionEnvironment) -> Bool {
        guard !command.contains("\n") else { return false }
        var groups: [[ShellToken]] = [[]]
        var confident = true
        for token in ShellTokenizer.tokenize(command) {
            if token.kind == .comment { break }
            if token.kind == .newline { confident = false; break }
            if token.unterminated { confident = false }
            if token.isSeparator {
                if !simpleSeparators.contains(token.text) { confident = false }
                groups.append([])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        var parsed = groups.compactMap(parse)
        if parsed.contains(where: { isSyntax($0.command) }) { confident = false }
        if !confident { parsed = groups.first.flatMap(parse).map { [$0] } ?? [] }
        if let first = parsed.first, isSyntax(first.command) { return true }

        var cwd: String? = directory
        for segment in parsed {
            if !validate(segment, cwd: &cwd, env: env) { return false }
        }
        return true
    }

    private struct Segment {
        let command: ShellToken
        let name: String?
        let args: [ShellToken]
        let redirectTargets: [ShellToken]
    }

    private static func isSyntax(_ token: ShellToken) -> Bool {
        keywords.contains(token.text)
    }

    private static func parse(_ group: [ShellToken]) -> Segment? {
        var plain: [ShellToken] = []
        var targets: [ShellToken] = []
        var expectTarget = false
        var skipNext = false
        for token in group {
            if token.isRedirect {
                if token.text.hasPrefix("<<") {
                    skipNext = true
                } else if let last = token.text.last, last == ">" || last == "<" || last == "|" || last == "&" {
                    expectTarget = true
                }
                continue
            }
            if skipNext { skipNext = false; continue }
            if expectTarget { expectTarget = false; targets.append(token); continue }
            plain.append(token)
        }

        var index = 0
        while index < plain.count, plain[index].isAssignment { index += 1 }
        while index < plain.count, wrappers.contains(plain[index].value) {
            let wrapper = plain[index].value
            index += 1
            while index < plain.count {
                let word = plain[index]
                if word.text.hasPrefix("-") {
                    if wrapper == "command", word.text == "-v" || word.text == "-V" { return nil }
                    index += 1
                    if wrapperValueOptions[wrapper]?.contains(word.text) == true { index += 1 }
                } else if wrapper == "env", word.isAssignment {
                    index += 1
                } else {
                    break
                }
            }
        }
        guard index < plain.count else { return nil }
        let command = plain[index]
        return Segment(command: command, name: literal(command), args: Array(plain[(index + 1)...]), redirectTargets: targets)
    }

    // The word's text only when it is fully known: no variables, substitutions, globs or open quotes.
    private static func literal(_ token: ShellToken) -> String? {
        guard token.kind == .word, !token.unterminated else { return nil }
        for part in token.parts where part.kind == .variable || part.kind == .substitution { return nil }
        let value = token.value
        if value.contains(where: { "*?[{$`".contains($0) }) { return nil }
        return value
    }

    private static func isPathLike(_ value: String) -> Bool {
        value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~/") || value.hasPrefix("/")
    }

    private static func isRelative(_ value: String) -> Bool {
        value.hasPrefix("./") || value.hasPrefix("../")
    }

    // `cwd` is updated to where the next segment runs (nil when a cd target cannot be resolved).
    private static func validate(_ segment: Segment, cwd: inout String?, env: CompletionEnvironment) -> Bool {
        let start = cwd
        if let name = segment.name, !alwaysAllowed.contains(name), !(isRelative(name) && start == nil) {
            if env.lookupCommand(name, directory: start ?? "/") == .missing { return false }
        }

        var pathArguments = segment.redirectTargets
        if segment.name == "cd" || segment.name == "pushd" {
            let operands = segment.args.filter { !$0.text.hasPrefix("-") || $0.text == "-" }
            if operands.isEmpty {
                cwd = segment.name == "cd" ? env.homeDirectory : nil
            } else if operands.count == 1 {
                switch changeDirectory(to: operands[0], cwd: start, env: env) {
                case .invalid: return false
                case .unknown: cwd = nil
                case .resolved(let path): cwd = path
                }
            } else {
                cwd = nil
            }
        } else {
            pathArguments += segment.args
        }

        for token in pathArguments {
            guard let value = literal(token), isPathLike(value) else { continue }
            if isRelative(value), start == nil { continue }
            let parent = parentDirectory(of: normalize(env.resolve(path: value, directory: start ?? "/")))
            if parent != "/", !env.fileExists(atPath: parent) { return false }
        }
        return true
    }

    private enum CDOutcome {
        case invalid
        case unknown
        case resolved(String)
    }

    private static func changeDirectory(to token: ShellToken, cwd: String?, env: CompletionEnvironment) -> CDOutcome {
        guard let value = literal(token), value != "-", !value.hasPrefix("+") else { return .unknown }
        if value.hasPrefix("~"), value != "~", !value.hasPrefix("~/") { return .unknown }
        let absolute = value.hasPrefix("/") || value.hasPrefix("~")
        if !absolute {
            guard cwd != nil else { return .unknown }
            // CDPATH can resolve a bare name against other roots.
            let bare = !isRelative(value) && value != "." && value != ".."
            if bare, !(env.variables["CDPATH"] ?? "").isEmpty { return .unknown }
        }
        let resolved = normalize(env.resolve(path: value, directory: cwd ?? "/"))
        guard resolved == "/" || env.fileExists(atPath: resolved) else { return .invalid }
        return .resolved(resolved)
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
