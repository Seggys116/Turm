import Foundation
import TurmCore

nonisolated enum CommandCompleteness {
    static func isComplete(_ text: String, fish: Bool = false) -> Bool {
        var state = State(fish: fish)
        var remaining = text
        while true {
            let tokens = ShellTokenizer.tokenize(remaining)
            var resume: String.Index?
            for token in tokens {
                if token.kind == .newline, !state.heredocs.isEmpty {
                    guard let end = state.skipHeredocs(remaining[token.range.upperBound...]) else { return false }
                    resume = end
                    break
                }
                state.consume(token)
            }
            guard let resume else { break }
            remaining = String(remaining[resume...])
        }
        return state.isComplete
    }

    private struct Heredoc {
        let delimiter: String
        let stripTabs: Bool
    }

    private struct State {
        let fish: Bool
        var blocks: [String] = []
        var parens = 0
        var commandStart = true
        var afterRedirect = false
        var pendingOperator = false
        var unterminated = false
        var trailingEscape = false
        var awaitingDelimiter: Bool?
        var heredocs: [Heredoc] = []

        var isComplete: Bool {
            !unterminated && !trailingEscape && !pendingOperator && blocks.isEmpty && parens == 0
                && heredocs.isEmpty && awaitingDelimiter == nil
        }

        mutating func consume(_ token: ShellToken) {
            trailingEscape = false
            switch token.kind {
            case .comment:
                break
            case .newline:
                commandStart = true
                afterRedirect = false
            case .op:
                operatorToken(token)
            case .word:
                word(token)
            }
        }

        private mutating func operatorToken(_ token: ShellToken) {
            let text = token.text
            awaitingDelimiter = nil
            afterRedirect = false
            if ["|", "||", "&&", "|&"].contains(text) {
                pendingOperator = true
                commandStart = true
            } else if [";", "&", ";;"].contains(text) {
                pendingOperator = false
                commandStart = true
            } else if text == "(" {
                parens += 1
                commandStart = true
            } else if text == ")" {
                parens = max(parens - 1, 0)
                commandStart = true
            } else if token.isRedirect {
                if String(text.drop(while: \.isNumber)) == "<<" { awaitingDelimiter = false } else { afterRedirect = true }
            }
        }

        private mutating func word(_ token: ShellToken) {
            pendingOperator = false
            if token.unterminated { unterminated = true }
            if let last = token.parts.last, last.kind == .escape, last.range.upperBound == token.range.upperBound,
               last.text == "\\" || last.text == "\\\n" {
                trailingEscape = true
            }
            if let stripTabs = awaitingDelimiter {
                heredoc(token, stripTabs: stripTabs)
                return
            }
            if afterRedirect {
                afterRedirect = false
                return
            }
            let text = token.text
            if text == "{" {
                blocks.append("}")
                commandStart = true
                return
            }
            if text == "}" {
                if blocks.last == "}" { blocks.removeLast() }
                commandStart = false
                return
            }
            guard commandStart, !token.isAssignment else { return }
            if fish { fishKeyword(text) } else { posixKeyword(text) }
        }

        private mutating func heredoc(_ token: ShellToken, stripTabs: Bool) {
            if token.text == "-", !stripTabs {
                awaitingDelimiter = true
                return
            }
            var delimiter = token.value
            var tabs = stripTabs
            if !stripTabs, token.text.hasPrefix("-"), token.text.count > 1 {
                delimiter.removeFirst()
                tabs = true
            }
            heredocs.append(Heredoc(delimiter: delimiter, stripTabs: tabs))
            awaitingDelimiter = nil
        }

        private mutating func posixKeyword(_ text: String) {
            switch text {
            case "if":
                blocks.append("fi")
                commandStart = true
            case "for", "while", "until", "select":
                blocks.append("done")
                commandStart = false
            case "case":
                blocks.append("esac")
                commandStart = false
            case "fi", "done", "esac":
                if blocks.last == text { blocks.removeLast() }
                commandStart = false
            case "then", "else", "elif", "do", "!", "time":
                commandStart = true
            default:
                commandStart = false
            }
        }

        private mutating func fishKeyword(_ text: String) {
            switch text {
            case "if", "while", "begin", "switch":
                blocks.append("end")
                commandStart = true
            case "for", "function":
                blocks.append("end")
                commandStart = false
            case "end":
                if blocks.last == "end" { blocks.removeLast() }
                commandStart = false
            case "else", "and", "or", "not", "case":
                commandStart = true
            default:
                commandStart = false
            }
        }

        mutating func skipHeredocs(_ body: Substring) -> String.Index? {
            var cursor = body.startIndex
            for doc in heredocs {
                while true {
                    let lineEnd = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
                    var line = body[cursor..<lineEnd]
                    if doc.stripTabs { line = line.drop(while: { $0 == "\t" }) }
                    let next = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
                    if line == doc.delimiter {
                        cursor = next
                        break
                    }
                    guard lineEnd < body.endIndex else { return nil }
                    cursor = next
                }
            }
            heredocs = []
            commandStart = true
            return cursor
        }
    }
}
