import Foundation

public nonisolated struct ShellToken: Equatable, Sendable {
    public nonisolated enum Kind: Equatable, Sendable {
        case word
        case op
        case comment
        case newline
    }

    public nonisolated struct Part: Equatable, Sendable {
        public nonisolated enum Kind: Equatable, Sendable {
            case plain
            case escape
            case singleQuoted
            case doubleQuoted
            case variable
            case substitution
        }

        public let kind: Kind
        public let range: Range<String.Index>
        public let text: String
        public let unterminated: Bool
    }

    public let kind: Kind
    public let range: Range<String.Index>
    public let text: String
    public let parts: [Part]
    public let unterminated: Bool

    public var isRedirect: Bool {
        kind == .op && (text.contains(">") || text.contains("<"))
    }

    public var isSeparator: Bool {
        switch kind {
        case .newline: return true
        case .op: return ["|", "||", "&&", ";", ";;", "&", "|&", "(", ")"].contains(text)
        default: return false
        }
    }

    public var value: String {
        guard kind == .word else { return text }
        var result = ""
        for part in parts {
            let raw = part.text
            switch part.kind {
            case .plain, .variable, .substitution:
                result += raw
            case .escape:
                result += raw.dropFirst()
            case .singleQuoted:
                result += Self.stripQuotes(raw, quote: "'")
            case .doubleQuoted:
                result += Self.stripQuotes(raw, quote: "\"")
            }
        }
        return result
    }

    public var isAssignment: Bool {
        guard kind == .word, let equals = text.firstIndex(of: "=") else { return false }
        let name = text[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func stripQuotes(_ raw: String, quote: Character) -> String {
        var body = Substring(raw)
        if body.first == quote { body = body.dropFirst() }
        if body.last == quote, body.count >= 1 { body = body.dropLast() }
        if quote == "\"" {
            var result = ""
            var escaped = false
            for character in body {
                if escaped {
                    if !"$`\"\\".contains(character) { result.append("\\") }
                    result.append(character)
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
        return String(body)
    }
}

public nonisolated enum ShellTokenizer {
    public static func tokenize(_ line: String) -> [ShellToken] {
        Lexer(line).run()
    }

    private nonisolated struct Lexer {
        typealias Part = ShellToken.Part

        let line: String
        let chars: [Character]
        let indices: [String.Index]

        init(_ line: String) {
            self.line = line
            chars = Array(line)
            indices = Array(line.indices) + [line.endIndex]
        }

        func run() -> [ShellToken] {
            var tokens: [ShellToken] = []
            var i = 0
            let n = chars.count
            while i < n {
                let c = chars[i]
                if c == "\n" || c == "\r\n" {
                    tokens.append(simple(.newline, i, i + 1))
                    i += 1
                } else if c.isWhitespace {
                    i += 1
                } else if c == "#" {
                    var j = i
                    while j < n, chars[j] != "\n" { j += 1 }
                    tokens.append(simple(.comment, i, j))
                    i = j
                } else if let length = operatorLength(at: i) {
                    tokens.append(simple(.op, i, i + length))
                    i += length
                } else {
                    let result = word(from: i)
                    tokens.append(result.token)
                    i = max(result.end, i + 1)
                }
            }
            return tokens
        }

        func simple(_ kind: ShellToken.Kind, _ start: Int, _ end: Int) -> ShellToken {
            let range = indices[start]..<indices[end]
            return ShellToken(kind: kind, range: range, text: String(line[range]), parts: [], unterminated: false)
        }

        func part(_ kind: Part.Kind, _ start: Int, _ end: Int, unterminated: Bool = false) -> Part {
            let range = indices[start]..<indices[end]
            return Part(kind: kind, range: range, text: String(line[range]), unterminated: unterminated)
        }

        func at(_ index: Int) -> Character? {
            index < chars.count ? chars[index] : nil
        }

        func isDigit(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.isASCII && c.isNumber
        }

        func startsVariable(_ next: Character?) -> Bool {
            guard let next else { return false }
            return next == "(" || next == "{" || next == "_" || next.isLetter || isDigit(next) || "?$!#@*-".contains(next)
        }

        func operatorLength(at i: Int) -> Int? {
            var start = i
            while isDigit(at(start)) { start += 1 }
            if start > i, let next = at(start), next == "<" || next == ">", at(start + 1) != "(" {
                return redirectLength(at: start) + (start - i)
            }
            switch chars[i] {
            case "|":
                return at(i + 1) == "|" || at(i + 1) == "&" ? 2 : 1
            case "&":
                if at(i + 1) == "&" { return 2 }
                if at(i + 1) == ">" { return at(i + 2) == ">" ? 3 : 2 }
                return 1
            case ";":
                return at(i + 1) == ";" ? 2 : 1
            case "(", ")":
                return 1
            case "<", ">":
                if at(i + 1) == "(" { return nil }
                return redirectLength(at: i)
            default:
                return nil
            }
        }

        func redirectLength(at i: Int) -> Int {
            var length = 1
            let first = chars[i]
            if at(i + 1) == first {
                length = 2
                if first == "<", at(i + 2) == "<" { length = 3 }
            } else if first == ">", at(i + 1) == "|" {
                length = 2
            } else if first == "<", at(i + 1) == ">" {
                length = 2
            }
            if at(i + length) == "&" {
                var probe = i + length + 1
                let digitsStart = probe
                while isDigit(at(probe)) { probe += 1 }
                if probe > digitsStart {
                    length = probe - i
                } else if at(probe) == "-" {
                    length = probe + 1 - i
                } else {
                    length += 1
                }
            }
            return length
        }

        func word(from start: Int) -> (token: ShellToken, end: Int) {
            var i = start
            var parts: [Part] = []
            var plainStart: Int?
            var unterminated = false
            let n = chars.count

            func flush(_ end: Int) {
                if let begin = plainStart, end > begin { parts.append(part(.plain, begin, end)) }
                plainStart = nil
            }

            while i < n {
                let c = chars[i]
                if c.isWhitespace || "|&;()".contains(c) { break }
                if c == "<" || c == ">" {
                    guard at(i + 1) == "(" else { break }
                    flush(i)
                    let end = scanParens(from: i + 1)
                    parts.append(part(.substitution, i, end.index, unterminated: end.unterminated))
                    unterminated = unterminated || end.unterminated
                    i = end.index
                    continue
                }
                switch c {
                case "\\":
                    flush(i)
                    let end = min(i + 2, n)
                    parts.append(part(.escape, i, end))
                    i = end
                case "'":
                    flush(i)
                    var j = i + 1
                    while j < n, chars[j] != "'" { j += 1 }
                    let closed = j < n
                    let end = closed ? j + 1 : n
                    parts.append(part(.singleQuoted, i, end, unterminated: !closed))
                    unterminated = unterminated || !closed
                    i = end
                case "\"":
                    flush(i)
                    let end = doubleQuoted(from: i, into: &parts)
                    unterminated = unterminated || end.unterminated
                    i = end.index
                case "$" where startsVariable(at(i + 1)):
                    flush(i)
                    let end = variable(from: i)
                    parts.append(part(end.kind, i, end.index, unterminated: end.unterminated))
                    unterminated = unterminated || end.unterminated
                    i = end.index
                case "`":
                    flush(i)
                    var j = i + 1
                    while j < n, chars[j] != "`" { j += chars[j] == "\\" ? 2 : 1 }
                    j = min(j, n)
                    let closed = j < n
                    let end = closed ? j + 1 : n
                    parts.append(part(.substitution, i, end, unterminated: !closed))
                    unterminated = unterminated || !closed
                    i = end
                default:
                    if plainStart == nil { plainStart = i }
                    i += 1
                }
            }
            flush(i)
            let range = indices[start]..<indices[i]
            let token = ShellToken(kind: .word, range: range, text: String(line[range]), parts: parts, unterminated: unterminated)
            return (token, i)
        }

        func scanParens(from open: Int) -> (index: Int, unterminated: Bool) {
            var depth = 0
            var j = open
            let n = chars.count
            while j < n {
                switch chars[j] {
                case "\\":
                    j += 1
                case "'":
                    j += 1
                    while j < n, chars[j] != "'" { j += 1 }
                case "\"":
                    j += 1
                    while j < n, chars[j] != "\"" {
                        if chars[j] == "\\" { j += 1 }
                        j += 1
                    }
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return (j + 1, false) }
                default:
                    break
                }
                j += 1
            }
            return (n, true)
        }

        func variable(from i: Int) -> (index: Int, kind: Part.Kind, unterminated: Bool) {
            let next = chars[i + 1]
            if next == "(" {
                let end = scanParens(from: i + 1)
                return (end.index, .substitution, end.unterminated)
            }
            if next == "{" {
                var j = i + 2
                while j < chars.count, chars[j] != "}" { j += 1 }
                let closed = j < chars.count
                return (closed ? j + 1 : chars.count, .variable, !closed)
            }
            if next.isLetter || next == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                return (j, .variable, false)
            }
            return (i + 2, .variable, false)
        }

        func doubleQuoted(from i: Int, into parts: inout [Part]) -> (index: Int, unterminated: Bool) {
            let first = parts.count
            var j = i + 1
            var pieceStart = i
            let n = chars.count
            while j < n {
                let c = chars[j]
                if c == "\\" {
                    j += 2
                } else if c == "\"" {
                    parts.append(part(.doubleQuoted, pieceStart, j + 1))
                    return (j + 1, false)
                } else if c == "$", startsVariable(at(j + 1)), at(j + 1) != "-" {
                    if j > pieceStart { parts.append(part(.doubleQuoted, pieceStart, j)) }
                    let end = variable(from: j)
                    parts.append(part(end.kind, j, end.index, unterminated: end.unterminated))
                    j = end.index
                    pieceStart = j
                } else {
                    j += 1
                }
            }
            j = n
            if j > pieceStart { parts.append(part(.doubleQuoted, pieceStart, j)) }
            let opening = parts[first]
            parts[first] = Part(kind: opening.kind, range: opening.range, text: opening.text, unterminated: true)
            return (j, true)
        }
    }
}
