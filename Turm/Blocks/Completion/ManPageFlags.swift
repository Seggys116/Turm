import Foundation

nonisolated enum ManPageFlags {
    static func parse(_ text: String) -> [FlagInfo] {
        let lines = stripFormatting(text).components(separatedBy: "\n")
        var found: [FlagInfo] = []
        var seen = Set<String>()
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 1, trimmed.hasPrefix("-") else { continue }
            var spec = trimmed
            var description = ""
            if let gap = trimmed.range(of: "  ") ?? trimmed.range(of: "\t") {
                spec = String(trimmed[..<gap.lowerBound])
                description = String(trimmed[gap.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if index + 1 < lines.count {
                let next = lines[index + 1]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                let indent = next.prefix { $0 == " " }.count
                let currentIndent = raw.prefix { $0 == " " }.count
                if !nextTrimmed.isEmpty, !nextTrimmed.hasPrefix("-"), indent > currentIndent {
                    description = nextTrimmed
                }
            }
            for flag in parseSpec(spec, description: description) where seen.insert(flag.name).inserted {
                found.append(flag)
            }
        }
        return found
    }

    static func parseSpec(_ spec: String, description: String) -> [FlagInfo] {
        var result: [FlagInfo] = []
        let alternatives = spec.replacingOccurrences(of: " or ", with: ",")
            .replacingOccurrences(of: " | ", with: ",")
            .components(separatedBy: ",")
        for alternative in alternatives {
            let piece = alternative.trimmingCharacters(in: .whitespaces)
            guard piece.hasPrefix("-") else { continue }
            var name = ""
            for character in piece {
                if character.isWhitespace || character == "=" || character == "[" || character == "<" { break }
                name.append(character)
            }
            let rest = piece.dropFirst(name.count)
            guard isFlagName(name) else { continue }
            let trimmedRest = rest.trimmingCharacters(in: .whitespaces)
            let equals = rest.hasPrefix("=") || rest.hasPrefix("[=")
            let takesValue = !trimmedRest.isEmpty
            let placeholder = trimmedRest.drop { !($0.isLetter || $0.isNumber) }.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            result.append(FlagInfo(
                name: name,
                detail: summarize(description),
                takesValue: takesValue,
                usesEquals: equals && name.hasPrefix("--"),
                valueKind: takesValue ? ValueKind.guess(String(placeholder)) : .text
            ))
        }
        return result
    }

    static func isFlagName(_ name: String) -> Bool {
        guard name.count >= 2, name.hasPrefix("-") else { return false }
        let body = name.drop { $0 == "-" }
        guard let first = body.first, first.isLetter || first.isNumber || first == "@" || first == "?" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@?".contains($0)) }
            && name.prefix { $0 == "-" }.count <= 2
    }

    static func summarize(_ description: String) -> String? {
        let clean = description.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        return clean.count > 90 ? String(clean.prefix(87)) + "..." : clean
    }

    static func stripFormatting(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\u{8}" {
                if !output.isEmpty { output.removeLast() }
            } else {
                output.append(scalar)
            }
        }
        let cleaned = String(output)
        guard let escape = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") else { return cleaned }
        return escape.stringByReplacingMatches(
            in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
        )
    }

    static func parseSubcommands(_ text: String) -> [SubcommandInfo] {
        var found: [SubcommandInfo] = []
        var seen = Set<String>()
        var inSection = false
        for raw in stripFormatting(text).components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if raw.first?.isLetter == true {
                let header = raw.trimmingCharacters(in: .whitespaces)
                inSection = header == header.uppercased() && header.contains("COMMAND")
                continue
            }
            guard inSection, !trimmed.isEmpty, let gap = trimmed.range(of: "  ") else { continue }
            let name = String(trimmed[..<gap.lowerBound])
            guard name.count >= 2, let first = name.first, first.isLowercase,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  seen.insert(name).inserted
            else { continue }
            let detail = String(trimmed[gap.upperBound...]).trimmingCharacters(in: .whitespaces)
            found.append(SubcommandInfo(name: name, detail: summarize(detail)))
        }
        return found
    }

    static func loadText(command: String, timeout: TimeInterval = 4, base: [String: String]? = nil) -> String? {
        let man = "/usr/bin/man"
        guard isSafeName(command), FileManager.default.isExecutableFile(atPath: man) else { return nil }
        var environment = base ?? ProcessInfo.processInfo.environment
        environment["MANPAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["MANWIDTH"] = "200"
        environment["MAN_KEEP_FORMATTING"] = nil
        return ProcessRunner.run(man, arguments: [command], environment: environment, timeout: timeout)
    }

    static func load(command: String, timeout: TimeInterval = 4) -> [FlagInfo] {
        loadText(command: command, timeout: timeout).map(parse) ?? []
    }

    static func isSafeName(_ command: String) -> Bool {
        !command.isEmpty && command.count < 80
            && command.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
            && !command.hasPrefix("-")
    }
}

nonisolated enum ZshCompletionFlags {
    static func parse(_ text: String) -> [FlagInfo] {
        var found: [FlagInfo] = []
        var seen = Set<String>()
        func add(_ flag: FlagInfo) {
            if seen.insert(flag.name).inserted { found.append(flag) }
        }
        let whole = NSRange(text.startIndex..., in: text)

        let brace = try? NSRegularExpression(
            pattern: #"\{(--?[A-Za-z0-9@?][^},\s]*(?:,--?[A-Za-z0-9@?][^},\s]*)*)\}['"]?\[([^\]]*)\]((?::[^'"]*)?)"#
        )
        brace?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match, let names = text.slice(match.range(at: 1)), let detail = text.slice(match.range(at: 2)) else { return }
            let tail = text.slice(match.range(at: 3)) ?? ""
            for name in names.split(separator: ",") {
                add(FlagInfo(
                    name: stripSign(String(name)),
                    detail: ManPageFlags.summarize(detail),
                    takesValue: !tail.isEmpty,
                    valueKind: valueKind(tail)
                ))
            }
        }

        let single = try? NSRegularExpression(
            pattern: #"['"](?:\([^)]*\))?\*?(--?[A-Za-z0-9@?][A-Za-z0-9_.-]*)([=+]{0,2}-?)\[([^\]]*)\]((?::[^'"]*)?)"#
        )
        single?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match, let name = text.slice(match.range(at: 1)), let detail = text.slice(match.range(at: 3)) else { return }
            let sign = text.slice(match.range(at: 2)) ?? ""
            let tail = text.slice(match.range(at: 4)) ?? ""
            let takesValue = !sign.isEmpty || !tail.isEmpty
            add(FlagInfo(
                name: name,
                detail: ManPageFlags.summarize(detail),
                takesValue: takesValue,
                usesEquals: sign.hasPrefix("=") && name.hasPrefix("--"),
                valueKind: takesValue ? valueKind(tail) : .text
            ))
        }
        return found
    }

    static func valueKind(_ tail: String) -> ValueKind {
        var trimmed = tail
        while trimmed.hasPrefix("::") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return .text }
        let message = parts.count > 1 ? parts[1] : ""
        let action = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
        return ValueKind.fromZshAction(action, message: message)
    }

    static func parseSubcommands(_ text: String) -> [SubcommandInfo] {
        var found: [SubcommandInfo] = []
        var seen = Set<String>()
        guard let entry = try? NSRegularExpression(pattern: #"['"]([a-z][A-Za-z0-9_-]*)\\?:([^'":\[\]]*)['"]"#) else { return [] }
        entry.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let name = text.slice(match.range(at: 1)), name.count >= 2, seen.insert(name).inserted else { return }
            let detail = text.slice(match.range(at: 2)).map { $0.replacingOccurrences(of: "\\", with: "") }
            found.append(SubcommandInfo(name: name, detail: detail.flatMap(ManPageFlags.summarize)))
        }
        return found
    }

    private static func stripSign(_ name: String) -> String {
        guard let cut = name.firstIndex(where: { $0 == "=" || $0 == "+" }) else { return name }
        return String(name[..<cut])
    }

    static func directories() -> [String] {
        var dirs: [String] = []
        let root = "/usr/share/zsh"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for version in versions.sorted(by: >) where version.first?.isNumber == true {
                dirs.append("\(root)/\(version)/functions")
                dirs.append("\(root)/\(version)/functions/Completion")
                for group in ["Unix", "Base", "Zsh", "Linux", "Darwin", "BSD"] {
                    dirs.append("\(root)/\(version)/functions/Completion/\(group)")
                }
            }
        }
        dirs += [
            "/opt/homebrew/share/zsh/site-functions",
            "/usr/local/share/zsh/site-functions",
            "/usr/share/zsh/site-functions",
            "/usr/share/zsh/vendor-completions",
        ]
        return dirs
    }

    static func loadText(command: String) -> String? {
        guard ManPageFlags.isSafeName(command) else { return nil }
        for directory in directories() {
            let path = directory + "/_" + command
            guard let data = FileManager.default.contents(atPath: path), data.count < 2_000_000 else { continue }
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    static func load(command: String) -> [FlagInfo] {
        loadText(command: command).map(parse) ?? []
    }
}

nonisolated enum CommandSpecLoader {
    static func load(command: String, environment: [String: String]? = nil) -> CommandSpec {
        var spec = CommandSpec()
        if let zsh = ZshCompletionFlags.loadText(command: command) {
            spec.flags = ZshCompletionFlags.parse(zsh)
            spec.subcommands = ZshCompletionFlags.parseSubcommands(zsh)
        }
        if let man = ManPageFlags.loadText(command: command, base: environment) {
            let knownFlags = Set(spec.flags.map(\.name))
            spec.flags += ManPageFlags.parse(man).filter { !knownFlags.contains($0.name) }
            let knownSubs = Set(spec.subcommands.map(\.name))
            spec.subcommands += ManPageFlags.parseSubcommands(man).filter { !knownSubs.contains($0.name) }
        }
        return spec
    }
}

private extension String {
    nonisolated func slice(_ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
