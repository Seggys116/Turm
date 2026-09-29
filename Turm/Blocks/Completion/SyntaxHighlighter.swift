import Foundation

nonisolated enum HighlightKind: Equatable, Sendable {
    case command
    case builtin
    case alias
    case function
    case keyword
    case unknownCommand
    case flag
    case string
    case variable
    case existingPath
    case op
    case redirect
    case comment
    case group
    case error
}

nonisolated struct HighlightSpan: Equatable, Sendable {
    let range: NSRange
    let kind: HighlightKind
}

nonisolated enum SyntaxHighlighter {
    static let maxLength = 4000
    static let closingKeywords: Set<String> = ["fi", "done", "esac", "in", "for", "case", "select", "function", "coproc"]

    static func spans(for line: String, directory: String, environment env: CompletionEnvironment) -> [HighlightSpan] {
        guard !line.isEmpty, line.utf16.count <= maxLength else { return [] }
        let tokens = ShellTokenizer.tokenize(line)
        var spans: [HighlightSpan] = []
        var expectCommand = true
        var scanner = CommandScanner()
        var awaitingTarget = false
        var groups: [(kind: String, token: ShellToken)] = []

        func add(_ range: Range<String.Index>, _ kind: HighlightKind) {
            spans.append(HighlightSpan(range: NSRange(range, in: line), kind: kind))
        }

        for token in tokens {
            switch token.kind {
            case .newline:
                expectCommand = true
                scanner = CommandScanner()
                awaitingTarget = false
            case .comment:
                add(token.range, .comment)
            case .op:
                if token.isRedirect {
                    add(token.range, .redirect)
                    awaitingTarget = !CommandCompleter.hasInlineTarget(token.text)
                    continue
                }
                switch token.text {
                case "(":
                    add(token.range, .group)
                    groups.append(("(", token))
                    expectCommand = true
                case ")":
                    if let index = groups.lastIndex(where: { $0.kind == "(" }) {
                        groups.remove(at: index)
                        add(token.range, .group)
                    } else {
                        add(token.range, .error)
                    }
                    expectCommand = false
                default:
                    add(token.range, .op)
                    expectCommand = true
                }
                scanner = CommandScanner()
                awaitingTarget = false
            case .word:
                if awaitingTarget {
                    awaitingTarget = false
                    styleArgument(token, in: line, directory: directory, env: env, into: &spans)
                    continue
                }
                if expectCommand {
                    if scanner.isIdle {
                        if token.text == "{" {
                            add(token.range, .group)
                            groups.append(("{", token))
                            continue
                        }
                        if closingKeywords.contains(token.text) || token.text == "}" {
                            if token.text == "}" {
                                if let index = groups.lastIndex(where: { $0.kind == "{" }) {
                                    groups.remove(at: index)
                                    add(token.range, .group)
                                } else {
                                    add(token.range, .error)
                                }
                            } else {
                                add(token.range, .keyword)
                            }
                            expectCommand = false
                            continue
                        }
                    }
                    switch scanner.classify(token) {
                    case .assignment:
                        styleAssignment(token, in: line, into: &spans)
                    case .keyword:
                        add(token.range, .keyword)
                    case .wrapper:
                        styleCommand(token, in: line, directory: directory, env: env, into: &spans)
                    case .option:
                        add(token.range, .flag)
                    case .optionValue, .positional:
                        styleArgument(token, in: line, directory: directory, env: env, into: &spans)
                    case .command:
                        styleCommand(token, in: line, directory: directory, env: env, into: &spans)
                        expectCommand = false
                    }
                } else {
                    styleArgument(token, in: line, directory: directory, env: env, into: &spans)
                }
            }
        }
        for group in groups {
            add(group.token.range, .error)
        }
        return spans
    }

    private static func styleCommand(
        _ token: ShellToken, in line: String, directory: String, env: CompletionEnvironment, into spans: inout [HighlightSpan]
    ) {
        let hasExpansion = token.parts.contains { $0.kind == .variable || $0.kind == .substitution }
        let kind: HighlightKind
        if hasExpansion {
            kind = .command
        } else {
            switch env.lookupCommand(token.value, directory: directory) {
            case .executable: kind = .command
            case .builtin: kind = .builtin
            case .alias: kind = .alias
            case .function: kind = .function
            case .keyword: kind = .keyword
            case .missing: kind = .unknownCommand
            case .unknown: kind = .command
            }
        }
        spans.append(HighlightSpan(range: NSRange(token.range, in: line), kind: kind))
        for part in token.parts {
            if part.kind == .variable || part.kind == .substitution {
                spans.append(HighlightSpan(range: NSRange(part.range, in: line), kind: part.kind == .variable ? .variable : .group))
            }
            if part.unterminated {
                spans.append(errorSpan(for: part, in: line))
            }
        }
    }

    private static func styleAssignment(_ token: ShellToken, in line: String, into spans: inout [HighlightSpan]) {
        if let equals = token.text.firstIndex(of: "=") {
            let nameEnd = line.index(token.range.lowerBound, offsetBy: token.text.distance(from: token.text.startIndex, to: equals))
            spans.append(HighlightSpan(range: NSRange(token.range.lowerBound..<nameEnd, in: line), kind: .variable))
        }
        styleParts(token, in: line, into: &spans)
    }

    private static func styleArgument(
        _ token: ShellToken,
        in line: String,
        directory: String,
        env: CompletionEnvironment,
        into spans: inout [HighlightSpan]
    ) {
        let plainOnly = token.parts.allSatisfy { $0.kind == .plain || $0.kind == .escape }
        if plainOnly, token.text.hasPrefix("-"), token.text.count > 1 {
            spans.append(HighlightSpan(range: NSRange(token.range, in: line), kind: .flag))
            return
        }
        styleParts(token, in: line, into: &spans)
        let value = token.value
        let hasExpansion = token.parts.contains { $0.kind == .variable || $0.kind == .substitution }
        guard !value.isEmpty, !hasExpansion, !value.contains(where: { "*?[]{}".contains($0) }) else { return }
        if env.fileExists(atPath: env.resolve(path: value, directory: directory)) {
            spans.append(HighlightSpan(range: NSRange(token.range, in: line), kind: .existingPath))
        }
    }

    private static func styleParts(_ token: ShellToken, in line: String, into spans: inout [HighlightSpan]) {
        for part in token.parts {
            switch part.kind {
            case .singleQuoted, .doubleQuoted:
                spans.append(HighlightSpan(range: NSRange(part.range, in: line), kind: .string))
            case .variable:
                spans.append(HighlightSpan(range: NSRange(part.range, in: line), kind: .variable))
            case .substitution:
                spans.append(HighlightSpan(range: NSRange(part.range, in: line), kind: .group))
            case .plain, .escape:
                break
            }
            if part.unterminated {
                spans.append(errorSpan(for: part, in: line))
            }
        }
    }

    private static func errorSpan(for part: ShellToken.Part, in line: String) -> HighlightSpan {
        let end = line.index(after: part.range.lowerBound)
        return HighlightSpan(range: NSRange(part.range.lowerBound..<end, in: line), kind: .error)
    }
}
