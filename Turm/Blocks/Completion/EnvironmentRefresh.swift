import Foundation

nonisolated enum ProcessEnvironmentReader {
    static func parse(_ buffer: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard buffer.count > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0, argc < 100_000 else { return nil }
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        func next() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return text
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = next() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    static func read(pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))?.environment
    }
}

nonisolated enum EnvironmentRefreshPolicy {
    static let maxAge: TimeInterval = 60

    static let environmentCommands: Set<String> = [
        "export", "source", ".", "eval", "direnv", "nvm", "fnm", "pyenv", "conda", "mamba", "micromamba", "asdf", "mise",
        "rbenv", "volta", "unset", "deactivate", "activate",
    ]
    static let directoryCommands: Set<String> = ["cd", "pushd", "popd", "z"]

    static func isStale(lastCapture: Date?, now: Date) -> Bool {
        guard let lastCapture else { return true }
        return now.timeIntervalSince(lastCapture) > maxAge
    }

    static func commandMayChangeEnvironment(
        _ text: String, directory: String, shell: String, hasEnvFile: (String) -> Bool
    ) -> Bool {
        var segments: [[ShellToken]] = [[]]
        for token in ShellTokenizer.tokenize(text) {
            if token.isSeparator {
                segments.append([])
            } else if token.kind == .word {
                segments[segments.count - 1].append(token)
            }
        }
        for words in segments {
            guard let commandAt = CommandScanner.commandIndex(in: words).index else { continue }
            let name = (words[commandAt].value as NSString).lastPathComponent
            let args = words[(commandAt + 1)...]
            if environmentCommands.contains(name) { return true }
            if name == "set", shell == "fish", args.contains(where: { $0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("x") }) {
                return true
            }
            if directoryCommands.contains(name), hasEnvFile(directory + "/.envrc") || hasEnvFile(directory + "/.env") { return true }
        }
        return false
    }
}
