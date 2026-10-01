import Foundation
import TurmCore

nonisolated struct WrapperRule: Sendable {
    let valueOptions: [String: ValueKind]
    let positionals: Int

    init(valueOptions: [String: ValueKind] = [:], positionals: Int = 0) {
        self.valueOptions = valueOptions
        self.positionals = positionals
    }
}

nonisolated struct CommandScanner: Sendable {
    enum Role: Equatable {
        case assignment
        case keyword
        case wrapper
        case option
        case optionValue
        case positional
        case command
    }

    static let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!"]

    static let rules: [String: WrapperRule] = [
        "sudo": WrapperRule(valueOptions: [
            "-u": .user, "--user": .user, "-g": .group, "--group": .group, "-h": .host, "--host": .host,
            "-p": .text, "--prompt": .text, "-C": .text, "--close-from": .text, "-r": .text, "--role": .text,
            "-t": .text, "--type": .text, "-U": .user, "--other-user": .user, "-T": .text,
            "--command-timeout": .text, "-D": .directory, "--chdir": .directory, "-R": .directory, "--chroot": .directory,
        ]),
        "doas": WrapperRule(valueOptions: ["-u": .user, "-C": .file]),
        "env": WrapperRule(valueOptions: ["-u": .variable, "--unset": .variable, "-C": .directory, "--chdir": .directory, "-S": .text, "-P": .directory]),
        "time": WrapperRule(valueOptions: ["-f": .text, "-o": .file, "--format": .text, "--output": .file]),
        "command": WrapperRule(),
        "builtin": WrapperRule(),
        "exec": WrapperRule(valueOptions: ["-a": .text]),
        "nohup": WrapperRule(),
        "noglob": WrapperRule(),
        "xargs": WrapperRule(valueOptions: [
            "-I": .text, "-J": .text, "-L": .text, "-n": .text, "-P": .text, "-s": .text, "-E": .text,
            "-d": .text, "-a": .file, "-R": .text, "-S": .text,
        ]),
        "watch": WrapperRule(valueOptions: ["-n": .text, "--interval": .text]),
        "nice": WrapperRule(valueOptions: ["-n": .text, "--adjustment": .text]),
        "caffeinate": WrapperRule(valueOptions: ["-t": .text, "-w": .pid]),
        "timeout": WrapperRule(valueOptions: ["-s": .text, "--signal": .text, "-k": .text, "--kill-after": .text], positionals: 1),
        "stdbuf": WrapperRule(valueOptions: ["-i": .text, "-o": .text, "-e": .text]),
    ]

    private(set) var wrapper: String?
    private(set) var pendingOption: String?
    private(set) var positionalsLeft = 0
    private var optionsEnded = false

    var isIdle: Bool { wrapper == nil && pendingOption == nil }

    var pendingKind: ValueKind? {
        guard let wrapper, let option = pendingOption else { return nil }
        return Self.rules[wrapper]?.valueOptions[option]
    }

    mutating func classify(_ token: ShellToken) -> Role {
        let value = token.value
        if pendingOption != nil {
            pendingOption = nil
            return .optionValue
        }
        if token.isAssignment { return .assignment }
        guard let active = wrapper, let rule = Self.rules[active] else {
            if Self.keywords.contains(value) { return .keyword }
            return enter(value)
        }
        if !optionsEnded {
            if value == "--" {
                optionsEnded = true
                return .option
            }
            if token.text.hasPrefix("-"), token.text.count > 1 {
                if rule.valueOptions[value] != nil { pendingOption = value }
                return .option
            }
        }
        if positionalsLeft > 0 {
            positionalsLeft -= 1
            return .positional
        }
        wrapper = nil
        return enter(value)
    }

    private mutating func enter(_ value: String) -> Role {
        let base = (value as NSString).lastPathComponent
        guard let rule = Self.rules[base] else { return .command }
        wrapper = base
        positionalsLeft = rule.positionals
        optionsEnded = false
        return .wrapper
    }

    static func commandIndex(in words: [ShellToken]) -> (index: Int?, scanner: CommandScanner) {
        var scanner = CommandScanner()
        for (index, word) in words.enumerated() {
            if scanner.classify(word) == .command { return (index, scanner) }
        }
        return (nil, scanner)
    }
}
