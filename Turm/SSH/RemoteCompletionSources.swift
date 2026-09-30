import Foundation

nonisolated struct RemoteEntry: Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let isExecutable: Bool
}

nonisolated struct RemoteListing: Equatable, Sendable {
    let exists: Bool
    let entries: [RemoteEntry]
}

nonisolated struct RemoteValue<T: Sendable>: Sendable {
    let value: T?

    init(_ value: T?) {
        self.value = value
    }
}

nonisolated final class RemoteFetchRegistry: @unchecked Sendable {
    static let shared = RemoteFetchRegistry()

    private let lock = NSLock()
    private var running: Set<String> = []

    func begin(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.insert(token).inserted
    }

    func end(_ token: String) {
        lock.lock()
        running.remove(token)
        lock.unlock()
    }
}

nonisolated enum RemoteCompletionSources {
    static let defaultPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let readLimit = 262_144
    static let refsDivider = "--remotes--"

    static let builtins = [
        "alias", "bg", "bind", "break", "builtin", "cd", "command", "continue", "declare", "dirs", "disown", "echo",
        "enable", "eval", "exec", "exit", "export", "false", "fc", "fg", "getopts", "hash", "help", "history", "jobs",
        "kill", "let", "local", "logout", "popd", "printf", "pushd", "pwd", "read", "readonly", "return", "set",
        "shift", "shopt", "source", "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias",
        "unset", "wait",
    ]

    static let keywords = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
        "select", "time", "{", "}", "!", "[[", "]]",
    ]

    static func fetch<T: Sendable>(
        _ channel: RemoteChannel, key: String, ttl: TimeInterval, load: @escaping @Sendable (RemoteChannel) -> RemoteValue<T>?
    ) -> T? {
        guard Thread.isMainThread else {
            return channel.cached(key, for: ttl) { load(channel) }?.value
        }
        if let fresh: RemoteValue<T> = channel.cached(key, for: ttl, { nil }) { return fresh.value }
        let stale: RemoteValue<T>? = channel.cached(key, for: .greatestFiniteMagnitude, { nil })
        prefetch(channel, key: key, load: load)
        return stale?.value
    }

    private static func prefetch<T: Sendable>(
        _ channel: RemoteChannel, key: String, load: @escaping @Sendable (RemoteChannel) -> RemoteValue<T>?
    ) {
        let token = channel.socket + "\u{0}" + key
        guard RemoteFetchRegistry.shared.begin(token) else { return }
        Task.detached(priority: .utility) {
            let loaded: RemoteValue<T>? = channel.cached(key, for: 0) { load(channel) }
            RemoteFetchRegistry.shared.end(token)
            guard loaded != nil else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .completionEnvironmentChanged, object: nil)
            }
        }
    }

    static func shellPath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"" + RemoteChannel.quote(String(path.dropFirst())) }
        return RemoteChannel.quote(path)
    }

    static func listScript(_ path: String) -> String {
        """
        cd -- \(shellPath(path)) 2>/dev/null || exit 3
        for f in .[!.]* ..?* *; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case $f in *[[:cntrl:]]*) continue;; esac
        if [ -d "$f" ]; then printf 'D\\t%s\\n' "$f"
        elif [ -x "$f" ]; then printf 'X\\t%s\\n' "$f"
        else printf 'F\\t%s\\n' "$f"; fi
        done
        """
    }

    static func commandsScript(path: String) -> String {
        """
        p=\(RemoteChannel.quote(path))
        IFS=:
        for d in $p; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        for f in "$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        n=${f##*/}
        case $n in *[[:cntrl:]]*) continue;; esac
        printf '%s\\t%s\\n' "$n" "$d"
        done
        done
        """
    }

    static func refsScript(_ directory: String) -> String {
        """
        export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0
        cd -- \(shellPath(directory)) 2>/dev/null || exit 3
        git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags 2>/dev/null </dev/null || exit 4
        printf '%s\\n' '\(refsDivider)'
        git remote 2>/dev/null </dev/null
        exit 0
        """
    }

    static func readScript(_ path: String) -> String {
        """
        f=\(shellPath(path))
        [ -f "$f" ] || exit 3
        dd if="$f" bs=\(readLimit) count=1 2>/dev/null
        """
    }

    static let processesScript = "ps -Ao pid=,comm= 2>/dev/null </dev/null || ps -eo pid=,comm= 2>/dev/null </dev/null"

    static func parseListing(_ output: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), line.distance(from: line.startIndex, to: tab) == 1 else { continue }
            let name = String(line[line.index(after: tab)...])
            guard !name.isEmpty else { continue }
            switch line[line.startIndex] {
            case "D": entries.append(RemoteEntry(name: name, isDirectory: true, isExecutable: false))
            case "X": entries.append(RemoteEntry(name: name, isDirectory: false, isExecutable: true))
            case "F": entries.append(RemoteEntry(name: name, isDirectory: false, isExecutable: false))
            default: continue
            }
        }
        return entries
    }

    static func parseCommands(_ output: String, home: String?) -> [ShellSymbol] {
        var seen: Set<String> = []
        var found: [ShellSymbol] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, seen.insert(String(fields[0])).inserted else { continue }
            var label = String(fields[1])
            if let home, home.count > 1, label == home || label.hasPrefix(home + "/") { label = "~" + label.dropFirst(home.count) }
            found.append(ShellSymbol(name: String(fields[0]), kind: .executable, detail: label))
        }
        return found
    }

    static func symbols(executables: [ShellSymbol]) -> [ShellSymbol] {
        let shell = builtins.map { ShellSymbol(name: $0, kind: .builtin, detail: nil) }
            + keywords.map { ShellSymbol(name: $0, kind: .keyword, detail: nil) }
        let taken = Set(shell.map(\.name))
        return shell + executables.filter { !taken.contains($0.name) }
    }

    static func parseRefs(_ output: String) -> GitRefs {
        var refs = GitRefs()
        var inRemotes = false
        for line in output.split(separator: "\n") {
            if line == refsDivider {
                inRemotes = true
            } else if inRemotes {
                refs.remotes.append(String(line))
            } else if line.hasPrefix("refs/heads/") {
                refs.branches.append(String(line.dropFirst("refs/heads/".count)))
            } else if line.hasPrefix("refs/remotes/") {
                let name = String(line.dropFirst("refs/remotes/".count))
                if !name.hasSuffix("/HEAD") { refs.remoteBranches.append(name) }
            } else if line.hasPrefix("refs/tags/") {
                refs.tags.append(String(line.dropFirst("refs/tags/".count)))
            }
        }
        return refs
    }

    static func parseProcesses(_ output: String) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
            var name = parts[1...].joined(separator: " ")
            if name.hasPrefix("/"), let last = name.split(separator: "/").last { name = String(last) }
            result.append(ProcessEntry(pid: pid, name: name))
        }
        return result
    }
}
