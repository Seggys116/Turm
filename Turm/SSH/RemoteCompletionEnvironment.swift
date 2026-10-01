import Foundation
import TurmCore

nonisolated struct RemoteCompletionEnvironment: CompletionEnvironment {
    let base: CompletionEnvironment
    var channel: RemoteChannel? = nil

    var homeDirectory: String { channel?.home ?? "~" }
    var variables: [String: String] { channel?.environment ?? [:] }

    func commandSymbols() -> [ShellSymbol] { loadedCommands() ?? [] }
    func commandsLoaded() -> Bool { loadedCommands() != nil }

    func isExecutable(atPath path: String) -> Bool {
        guard case .found(let entry) = state(ofPath: path) else { return false }
        return !entry.isDirectory && entry.isExecutable
    }

    func fileExists(atPath path: String) -> Bool {
        if case .found = state(ofPath: path) { return true }
        return false
    }

    func directoryEntries(atPath path: String) -> [DirectoryEntry]? {
        guard let listing = listing(atPath: path), listing.exists else { return nil }
        return listing.entries.map { DirectoryEntry(name: $0.name, isDirectory: $0.isDirectory) }
    }

    func gitRefs(in directory: String) -> GitRefs? {
        guard let channel else { return nil }
        let script = RemoteCompletionSources.refsScript(directory)
        return RemoteCompletionSources.fetch(channel, key: "git:" + directory, ttl: 5) { channel in
            guard let result = channel.run(script, timeout: 2) else { return nil }
            switch result.status {
            case 0: return RemoteValue<GitRefs>(RemoteCompletionSources.parseRefs(result.output))
            case 3, 4: return RemoteValue<GitRefs>(nil)
            default: return nil
            }
        }
    }

    func readText(atPath path: String) -> String? {
        guard let channel else { return nil }
        let script = RemoteCompletionSources.readScript(path)
        return RemoteCompletionSources.fetch(channel, key: "text:" + path, ttl: 5) { channel in
            guard let result = channel.run(script, timeout: 2) else { return nil }
            switch result.status {
            case 0: return RemoteValue<String>(result.output)
            case 3: return RemoteValue<String>(nil)
            default: return nil
            }
        }
    }

    func processes() -> [ProcessEntry] {
        guard let channel else { return [] }
        let found: [ProcessEntry]? = RemoteCompletionSources.fetch(channel, key: "ps:", ttl: 3) { channel in
            guard let result = channel.run(RemoteCompletionSources.processesScript, timeout: 2), result.status == 0 else { return nil }
            return RemoteValue<[ProcessEntry]>(RemoteCompletionSources.parseProcesses(result.output))
        }
        return found ?? []
    }

    func flags(forCommand command: String) -> [FlagInfo] { base.flags(forCommand: command) }
    func commandSpec(forCommand command: String) -> CommandSpec { base.commandSpec(forCommand: command) }
    func dockerObjects() -> DockerObjects { DockerObjects() }
    func cliListing(_ invocation: CLIInvocation) -> [String] { [] }

    func lookupCommand(_ name: String, directory: String) -> CommandLookup {
        guard channel != nil else { return .unknown }
        if name.contains("/") || name.hasPrefix("~") {
            switch state(ofPath: resolve(path: name, directory: directory)) {
            case .unknown: return .unknown
            case .missing: return .missing
            case .found(let entry): return !entry.isDirectory && entry.isExecutable ? .executable : .missing
            }
        }
        let symbols = loadedCommands()
        return Self.lookupKind(name, in: symbols ?? [], loaded: symbols != nil)
    }

    func shortcuts(in directory: String) -> [Shortcut] { Shortcuts.load().filter { $0.kind == .command } }
    func sshHosts() -> [SSHHost] { base.sshHosts() }

    private enum PathState {
        case unknown
        case missing
        case found(RemoteEntry)
    }

    private func loadedCommands() -> [ShellSymbol]? {
        guard let channel else { return nil }
        let path = channel.environment["PATH"] ?? RemoteCompletionSources.defaultPath
        let home = channel.home
        let script = RemoteCompletionSources.commandsScript(path: path)
        return RemoteCompletionSources.fetch(channel, key: "commands:" + path, ttl: 300) { channel in
            guard let result = channel.run(script, timeout: 6), result.status == 0 else { return nil }
            let executables = RemoteCompletionSources.parseCommands(result.output, home: home)
            return RemoteValue<[ShellSymbol]>(RemoteCompletionSources.symbols(executables: executables))
        }
    }

    private func listing(atPath path: String) -> RemoteListing? {
        guard let channel else { return nil }
        let script = RemoteCompletionSources.listScript(path)
        return RemoteCompletionSources.fetch(channel, key: "ls:" + path, ttl: 3) { channel in
            guard let result = channel.run(script, timeout: 2) else { return nil }
            switch result.status {
            case 0: return RemoteValue<RemoteListing>(RemoteListing(exists: true, entries: RemoteCompletionSources.parseListing(result.output)))
            case 3: return RemoteValue<RemoteListing>(RemoteListing(exists: false, entries: []))
            default: return nil
            }
        }
    }

    private func state(ofPath raw: String) -> PathState {
        var path = raw
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let directoryEntry = RemoteEntry(name: path, isDirectory: true, isExecutable: false)
        if path == "/" || path == "~" { return .found(directoryEntry) }
        guard path.hasPrefix("/") || path.hasPrefix("~/"), let slash = path.lastIndex(of: "/") else { return .unknown }
        let name = String(path[path.index(after: slash)...])
        if name == "." || name == ".." { return .found(directoryEntry) }
        let parent = path[..<slash].isEmpty ? "/" : String(path[..<slash])
        guard let listing = listing(atPath: parent) else { return .unknown }
        guard listing.exists, let entry = listing.entries.first(where: { $0.name == name }) else { return .missing }
        return .found(entry)
    }
}
