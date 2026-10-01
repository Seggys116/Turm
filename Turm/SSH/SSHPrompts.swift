import Foundation
import TurmCore

nonisolated enum SSHPasswordPrompt {
    static func matches(_ tail: String, target: SSHTarget) -> Bool {
        let line = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasSuffix("password:") else { return false }
        let host = target.hostname.lowercased()
        let user = target.user.lowercased()
        let owners = ["\(user)@\(host)'s password:", "(\(user)@\(host)) password:"]
        return owners.contains(lower)
    }
}

nonisolated enum SudoPrompt {
    static func isSudo(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).first == "sudo"
    }

    static func matches(_ tail: String, user: String) -> Bool {
        guard !user.isEmpty, let line = tail.components(separatedBy: "\n").last else { return false }
        var trimmed = Substring(line)
        while trimmed.last == " " { trimmed.removeLast() }
        return trimmed == "[sudo] password for \(user):"
    }
}
