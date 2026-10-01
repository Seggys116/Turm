import Foundation
import TurmCore

nonisolated final class SystemCompletionEnvironment: CompletionEnvironment, @unchecked Sendable {
    static let shared = SystemCompletionEnvironment()

    private let clock: () -> Date
    private let probeOverride: (() -> String?)?
    private var lastCapture: Date?
    private var refreshing = false
    private var shellPID: Int32?
    private var launchEnvironment: [String: String] = [:]

    init(clock: @escaping () -> Date = { Date() }, probe: (() -> String?)? = nil) {
        self.clock = clock
        probeOverride = probe
    }

    let homeDirectory = NSHomeDirectory()
    private let lock = NSLock()
    private let baseVariables = ProcessInfo.processInfo.environment
    private var started = false
    private var pathScanned = false
    private var symbols: [ShellSymbol] = []
    private var kinds: [String: ShellSymbol.Kind] = [:]
    private var shellPath: String?
    private var shellVariables: Set<String> = []
    private var specCache: [String: CommandSpec] = [:]
    private var shellPathOverride: String?
    private var dockerCache: (time: Date, objects: DockerObjects)?
    private var captured: [String: String] = [:]
    private var live: [String: String] = [:]
    private var liveIsSnapshot = false
    private var listingsStorage: CLIListingCache?

    private func listings() -> CLIListingCache {
        lock.lock()
        defer { lock.unlock() }
        if let existing = listingsStorage { return existing }
        let made = CLIListingCache(
            locate: { [unowned self] in ProcessRunner.locate($0, in: self.pathDirectories()) },
            runner: { [unowned self] executable, arguments, timeout in
                ProcessRunner.run(
                    executable, arguments: arguments, environment: self.processEnvironment(), timeout: timeout, requireSuccess: true
                )
            }
        )
        listingsStorage = made
        return made
    }

    var variables: [String: String] {
        touch()
        lock.lock()
        defer { lock.unlock() }
        var merged = exportedEnvironment()
        for name in shellVariables where merged[name] == nil { merged[name] = "" }
        return merged
    }

    func processEnvironment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return exportedEnvironment()
    }

    private func exportedEnvironment() -> [String: String] {
        if liveIsSnapshot { return live }
        var merged = baseVariables
        for (key, value) in launchEnvironment { merged[key] = value }
        for (key, value) in captured { merged[key] = value }
        for (key, value) in live { merged[key] = value }
        return merged
    }

    func setShellProcess(pid: Int32?) {
        lock.lock()
        shellPID = pid
        lock.unlock()
    }

    private func touch() {
        lock.lock()
        let active = started
        lock.unlock()
        if active { refreshIfStale() }
    }

    func refreshIfStale(wait: Bool = false) {
        lock.lock()
        let stale = EnvironmentRefreshPolicy.isStale(lastCapture: lastCapture, now: clock())
        lock.unlock()
        if stale { refreshEnvironment(wait: wait) }
    }

    func commandFinished(_ command: String, directory: String, wait: Bool = false) {
        let shell = URL(fileURLWithPath: resolvedShell()).lastPathComponent
        let changes = EnvironmentRefreshPolicy.commandMayChangeEnvironment(
            command, directory: directory, shell: shell, hasEnvFile: { fileExists(atPath: $0) }
        )
        if changes { refreshEnvironment(wait: wait) }
    }

    func refreshEnvironment(wait: Bool = false) {
        lock.lock()
        if refreshing {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()
        let work = { [self] in
            let before = effectivePath()
            probeShell()
            readLaunchEnvironment()
            lock.lock()
            lastCapture = clock()
            refreshing = false
            lock.unlock()
            if before != effectivePath() { scanPath() } else { notify() }
        }
        if wait { work() } else { Task.detached(priority: .utility) { work() } }
    }

    private func readLaunchEnvironment() {
        lock.lock()
        let pid = shellPID
        lock.unlock()
        guard let pid, let live = ProcessEnvironmentReader.read(pid: pid) else { return }
        lock.lock()
        launchEnvironment = live
        lock.unlock()
    }

    func warmUp(shell: String? = nil) {
        lock.lock()
        let first = !started
        started = true
        shellPathOverride = shell
        lock.unlock()
        guard first else { return }
        Task.detached(priority: .utility) { [self] in
            scanPath()
            probeShell()
            readLaunchEnvironment()
            markCaptured()
            scanPath()
        }
    }

    private func effectivePath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return exportedEnvironment()["PATH"]
    }

    func applyLiveEnvironment(_ variables: [String: String], merge: Bool = false, wait: Bool = false) {
        let before = effectivePath()
        lock.lock()
        if merge {
            for (key, value) in variables { live[key] = value }
        } else {
            live = variables
            liveIsSnapshot = true
        }
        lastCapture = clock()
        lock.unlock()
        if before == effectivePath() {
            notify()
        } else if wait {
            scanPath()
        } else {
            Task.detached(priority: .utility) { [self] in scanPath() }
        }
    }

    private func markCaptured() {
        lock.lock()
        lastCapture = clock()
        lock.unlock()
    }

    func commandSymbols() -> [ShellSymbol] {
        touch()
        lock.lock()
        defer { lock.unlock() }
        return symbols
    }

    func commandsLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pathScanned
    }

    func lookupCommand(_ name: String, directory: String) -> CommandLookup {
        if name.contains("/") || name.hasPrefix("~") {
            return isExecutable(atPath: resolve(path: name, directory: directory)) ? .executable : .missing
        }
        lock.lock()
        defer { lock.unlock() }
        if let kind = kinds[name] { return CommandLookup(kind) }
        return pathScanned ? .missing : .unknown
    }

    func isExecutable(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func directoryEntries(atPath path: String) -> [DirectoryEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDirectory)
            return DirectoryEntry(name: name, isDirectory: isDirectory.boolValue)
        }
    }

    func gitRefs(in directory: String) -> GitRefs? {
        guard let git = gitExecutable() else { return nil }
        var environment = processEnvironment()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let output = ProcessRunner.run(
            git,
            arguments: ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
            environment: environment,
            directory: directory,
            timeout: 3
        ) else { return nil }
        var refs = GitRefs()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("refs/heads/") {
                refs.branches.append(String(line.dropFirst("refs/heads/".count)))
            } else if line.hasPrefix("refs/remotes/") {
                let name = String(line.dropFirst("refs/remotes/".count))
                if !name.hasSuffix("/HEAD") { refs.remoteBranches.append(name) }
            } else if line.hasPrefix("refs/tags/") {
                refs.tags.append(String(line.dropFirst("refs/tags/".count)))
            }
        }
        let remotes = ProcessRunner.run(git, arguments: ["remote"], environment: environment, directory: directory, timeout: 3)
        refs.remotes = remotes?.split(separator: "\n").map(String.init) ?? []
        return refs
    }

    func flags(forCommand command: String) -> [FlagInfo] {
        commandSpec(forCommand: command).flags
    }

    func shortcuts(in directory: String) -> [Shortcut] {
        Shortcuts.merged(Shortcuts.load(), project: ProjectShortcutIndex.shared.shortcuts(for: directory))
    }

    func sshHosts() -> [SSHHost] {
        SSHHostStore.load()
    }

    func commandSpec(forCommand command: String) -> CommandSpec {
        lock.lock()
        if let cached = specCache[command] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let spec = CommandSpecLoader.load(command: command, environment: processEnvironment())
        lock.lock()
        specCache[command] = spec
        lock.unlock()
        return spec
    }

    func readText(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12_000_000) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func dockerObjects() -> DockerObjects {
        lock.lock()
        if let cached = dockerCache, Date().timeIntervalSince(cached.time) < 5 {
            lock.unlock()
            return cached.objects
        }
        lock.unlock()
        var objects = DockerObjects()
        let variables = self.variables
        if let socket = DockerEngine.socketPath(
            variables: variables, home: homeDirectory, readText: { self.readText(atPath: $0) }, exists: { self.fileExists(atPath: $0) }
        ) {
            objects = DockerEngine.load(socket: socket)
        }
        lock.lock()
        dockerCache = (Date(), objects)
        lock.unlock()
        return objects
    }

    func cliListing(_ invocation: CLIInvocation) -> [String] {
        lock.lock()
        let cache = listings()
        lock.unlock()
        return cache.lines(invocation)
    }

    func processes() -> [ProcessEntry] {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) + 64)
        _ = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [ProcessEntry] = []
        for pid in pids where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            result.append(ProcessEntry(pid: Int(pid), name: String(cString: name)))
        }
        return result
    }

    private func gitExecutable() -> String? {
        ProcessRunner.locate("git", in: pathDirectories()) ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil)
    }

    private func pathDirectories() -> [String] {
        lock.lock()
        let snapshot = liveIsSnapshot
        let shell = exportedEnvironment()["PATH"] ?? shellPath
        lock.unlock()
        var directories: [String] = []
        for source in snapshot ? [shell] : [shell, baseVariables["PATH"]] {
            for directory in (source ?? "").split(separator: ":") where !directory.isEmpty {
                let path = String(directory)
                if !directories.contains(path) { directories.append(path) }
            }
        }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !directories.contains(extra) {
            directories.append(extra)
        }
        return directories
    }

    private func scanPath() {
        var found: [String: ShellSymbol] = [:]
        for directory in pathDirectories() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            let label = directory.hasPrefix(homeDirectory) ? "~" + directory.dropFirst(homeDirectory.count) : directory
            for name in names where found[name] == nil {
                if FileManager.default.isExecutableFile(atPath: directory + "/" + name) {
                    found[name] = ShellSymbol(name: name, kind: .executable, detail: label)
                }
            }
        }
        lock.lock()
        let shellOnly = symbols.filter { $0.kind != .executable }
        let shellNames = Set(shellOnly.map(\.name))
        symbols = shellOnly + found.values.filter { !shellNames.contains($0.name) }
        rebuildKinds()
        pathScanned = true
        lock.unlock()
        notify()
    }

    private func rebuildKinds() {
        var table: [String: ShellSymbol.Kind] = [:]
        for symbol in symbols where table[symbol.name] == nil { table[symbol.name] = symbol.kind }
        kinds = table
    }

    private func resolvedShell() -> String {
        lock.lock()
        let override = shellPathOverride
        lock.unlock()
        if let override, FileManager.default.isExecutableFile(atPath: override) { return override }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if Self.probeScript(shellName: URL(fileURLWithPath: path).lastPathComponent) != nil,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/bin/zsh"
    }

    private func probeShell() {
        guard let output = runProbe() else { return }
        parseProbe(output)
    }

    private func runProbe() -> String? {
        if let probeOverride { return probeOverride() }
        let shell = resolvedShell()
        guard let script = Self.probeScript(shellName: URL(fileURLWithPath: shell).lastPathComponent) else { return nil }
        var environment = baseVariables
        environment["TERM"] = "dumb"
        environment["TURM_PROBE"] = "1"
        let flag = shell.hasSuffix("fish") ? "-ic" : "-ilc"
        return ProcessRunner.run(shell, arguments: [flag, script], environment: environment, timeout: 8)
    }

    static func probeScript(shellName: String) -> String? {
        switch shellName {
        case "zsh": return zshProbe
        case "bash": return bashProbe
        case "fish": return fishProbe
        default: return nil
        }
    }

    static let envBegin = "\u{1}ENVBEGIN\u{2}"
    static let envEnd = "\u{1}ENVEND\u{2}"

    static func splitEnvironment(_ output: String) -> (rest: String, environment: [String: String]) {
        guard let begin = output.range(of: envBegin), let end = output.range(of: envEnd, range: begin.upperBound..<output.endIndex) else {
            return (output, [:])
        }
        var environment: [String: String] = [:]
        for entry in output[begin.upperBound..<end.lowerBound].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (String(output[..<begin.lowerBound]) + String(output[end.upperBound...]), environment)
    }

    func parseProbe(_ fullOutput: String) {
        let split = Self.splitEnvironment(fullOutput)
        let output = split.rest
        var parsed: [ShellSymbol] = []
        var variableNames: Set<String> = []
        var path: String?
        for line in output.split(separator: "\n") where line.hasPrefix("\u{1}") {
            let fields = line.split(separator: "\u{1}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let tag = fields[1]
            let rest = fields[2].split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = rest.first.map(String.init), !name.isEmpty else { continue }
            let detail = rest.count > 1 ? String(rest[1]) : nil
            switch tag {
            case "a": parsed.append(ShellSymbol(name: name, kind: .alias, detail: detail))
            case "f": parsed.append(ShellSymbol(name: name, kind: .function, detail: nil))
            case "b": parsed.append(ShellSymbol(name: name, kind: .builtin, detail: nil))
            case "k": parsed.append(ShellSymbol(name: name, kind: .keyword, detail: nil))
            case "v": variableNames.insert(name)
            case "p": path = name
            default: break
            }
        }
        lock.lock()
        let executables = symbols.filter { $0.kind == .executable }
        symbols = parsed + executables
        rebuildKinds()
        shellVariables = variableNames.filter { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }
        if let path, !path.isEmpty { shellPath = path }
        if !split.environment.isEmpty { captured = split.environment }
        lock.unlock()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .completionEnvironmentChanged, object: nil)
        }
    }

    static let zshProbe = """
    m=$'\\001'
    for k in ${(k)aliases}; do print -r -- "${m}a${m}${k}${m}${aliases[$k]}"; done
    for k in ${(k)functions}; do print -r -- "${m}f${m}${k}"; done
    for k in ${(k)builtins}; do print -r -- "${m}b${m}${k}"; done
    for k in ${(k)reswords}; do print -r -- "${m}k${m}${k}"; done
    for k in ${(k)parameters}; do print -r -- "${m}v${m}${k}"; done
    print -r -- "${m}p${m}${PATH}"
    printf '\\001ENVBEGIN\\002'; command env -0; printf '\\001ENVEND\\002'
    """

    static let fishProbe = """
    set -l m (printf '\\001')
    for k in (functions -n)
        printf '%sf%s%s\\n' $m $m $k
    end
    for k in (builtin -n)
        printf '%sb%s%s\\n' $m $m $k
    end
    for line in (abbr --show)
        set -l parts (string match -r -- '-- (\\S+) ?(.*)$' -- $line)
        if test (count $parts) -ge 2
            printf '%sa%s%s%s%s\\n' $m $m $parts[2] $m "$parts[3]"
        end
    end
    for k in (set -n)
        printf '%sv%s%s\\n' $m $m $k
    end
    printf '%sp%s%s\\n' $m $m (string join : $PATH)
    printf '\\001ENVBEGIN\\002'; command env -0; printf '\\001ENVEND\\002'
    """

    static let bashProbe = """
    m=$'\\001'
    for k in $(compgen -a); do printf '%s\\n' "${m}a${m}${k}${m}${BASH_ALIASES[$k]}"; done
    for k in $(compgen -A function); do printf '%s\\n' "${m}f${m}${k}"; done
    for k in $(compgen -b); do printf '%s\\n' "${m}b${m}${k}"; done
    for k in $(compgen -k); do printf '%s\\n' "${m}k${m}${k}"; done
    for k in $(compgen -v); do printf '%s\\n' "${m}v${m}${k}"; done
    printf '%s\\n' "${m}p${m}${PATH}"
    printf '\\001ENVBEGIN\\002'; command env -0; printf '\\001ENVEND\\002'
    """
}
