import Foundation

nonisolated struct CompletionItem: Equatable, Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case command
        case builtin
        case alias
        case function
        case keyword
        case file
        case directory
        case variable
        case flag
        case branch
        case remote
        case tag
        case subcommand
        case history
        case package
        case host
        case user
        case group
        case script
        case target
        case process
        case choice
        case container
        case image
        case resource
        case context
        case service
        case profile
        case version
        case environment
        case namespace
        case workspace
        case volume
        case network
        case project
        case release
        case chart
        case repo
        case shortcut

        var label: String {
            switch self {
            case .command: return "command"
            case .builtin: return "builtin"
            case .alias: return "alias"
            case .function: return "function"
            case .keyword: return "keyword"
            case .file: return "file"
            case .directory: return "folder"
            case .variable: return "variable"
            case .flag: return "flag"
            case .branch: return "branch"
            case .remote: return "remote"
            case .tag: return "tag"
            case .subcommand: return "subcommand"
            case .history: return "history"
            case .package: return "package"
            case .host: return "host"
            case .user: return "user"
            case .group: return "group"
            case .script: return "script"
            case .target: return "target"
            case .process: return "process"
            case .choice: return "value"
            case .container: return "container"
            case .image: return "image"
            case .resource: return "resource"
            case .context: return "context"
            case .service: return "service"
            case .profile: return "profile"
            case .version: return "version"
            case .environment: return "environment"
            case .namespace: return "namespace"
            case .workspace: return "workspace"
            case .volume: return "volume"
            case .network: return "network"
            case .project: return "project"
            case .release: return "release"
            case .chart: return "chart"
            case .repo: return "repository"
            case .shortcut: return "shortcut"
            }
        }

        var symbol: String {
            switch self {
            case .command, .builtin, .function, .keyword: return "terminal"
            case .alias: return "arrow.turn.down.right"
            case .file: return "doc"
            case .directory: return "folder"
            case .variable: return "dollarsign"
            case .flag: return "flag"
            case .branch, .remote: return "arrow.triangle.branch"
            case .tag: return "tag"
            case .subcommand: return "chevron.right.square"
            case .history: return "clock.arrow.circlepath"
            case .package: return "shippingbox"
            case .host: return "network"
            case .user, .group: return "person"
            case .script, .target: return "play"
            case .process: return "cpu"
            case .choice: return "list.bullet"
            case .container: return "shippingbox"
            case .image: return "photo.stack"
            case .resource: return "square.stack.3d.up"
            case .context, .namespace: return "point.3.connected.trianglepath.dotted"
            case .service: return "server.rack"
            case .profile: return "person.crop.circle"
            case .version: return "number"
            case .environment: return "leaf"
            case .workspace: return "square.grid.2x2"
            case .volume: return "externaldrive"
            case .network: return "network"
            case .project: return "folder.badge.gearshape"
            case .release: return "shippingbox.fill"
            case .chart: return "shippingbox"
            case .repo: return "books.vertical"
            case .shortcut: return "at"
            }
        }
    }

    let insert: String
    let display: String
    let kind: Kind
    let detail: String?
    let terminator: String

    init(insert: String, display: String? = nil, kind: Kind, detail: String? = nil, terminator: String = " ") {
        self.insert = insert
        self.display = display ?? insert
        self.kind = kind
        self.detail = detail
        self.terminator = terminator
    }

    var id: String { kind.rawValue + "\u{0}" + insert }
}

nonisolated struct CompletionResult: Equatable, Sendable {
    let range: Range<String.Index>
    let items: [CompletionItem]
}

nonisolated struct DirectoryEntry: Equatable, Sendable {
    let name: String
    let isDirectory: Bool
}

nonisolated struct GitRefs: Equatable, Sendable {
    var branches: [String] = []
    var remoteBranches: [String] = []
    var tags: [String] = []
    var remotes: [String] = []
}

nonisolated enum ValueKind: Equatable, Sendable {
    case text
    case file
    case directory
    case user
    case group
    case host
    case variable
    case pid
    case command
    case choices([String])

    static func guess(_ placeholder: String) -> ValueKind {
        let word = placeholder.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "<>[]=.,: "))
        guard !word.isEmpty else { return .text }
        if word.contains("dir") || word.contains("folder") { return .directory }
        if word.contains("file") || word.contains("path") || word.contains("script") || word == "config" { return .file }
        if word.contains("user") || word == "login" { return .user }
        if word.contains("group") { return .group }
        if word.contains("host") || word == "destination" { return .host }
        if word == "pid" || word == "process" { return .pid }
        if word.contains("envvar") || word == "var" || word == "variable" { return .variable }
        return .text
    }

    static func fromZshAction(_ raw: String, message: String = "") -> ValueKind {
        let action = raw.trimmingCharacters(in: .whitespaces)
        if action.hasPrefix("("), action.hasSuffix(")") {
            let inner = action.dropFirst().dropLast()
            let choices = inner.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { piece -> String in
                let word = piece.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(piece)
                return word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"\\"))
            }.filter { !$0.isEmpty }
            return choices.isEmpty ? .text : .choices(choices)
        }
        let head = action.split(separator: " ").first.map(String.init) ?? action
        switch head {
        case "_files", "_path_files":
            return action.contains("-/") ? .directory : .file
        case "_directories", "_cd", "_dirs":
            return .directory
        case "_users", "_user_at_host":
            return .user
        case "_groups":
            return .group
        case "_hosts", "_ssh_hosts", "_known_hosts", "_hostnames":
            return .host
        case "_parameters", "_vars", "_env_variables":
            return .variable
        case "_pids":
            return .pid
        case "_command_names", "_commands", "_precommand":
            return .command
        default:
            return action.isEmpty ? guess(message) : .text
        }
    }
}

nonisolated struct FlagInfo: Equatable, Sendable {
    let name: String
    let detail: String?
    let takesValue: Bool
    let usesEquals: Bool
    let valueKind: ValueKind

    init(name: String, detail: String? = nil, takesValue: Bool = false, usesEquals: Bool = false, valueKind: ValueKind = .text) {
        self.name = name
        self.detail = detail
        self.takesValue = takesValue
        self.usesEquals = usesEquals
        self.valueKind = valueKind
    }
}

nonisolated struct SubcommandInfo: Equatable, Sendable {
    let name: String
    let detail: String?
}

nonisolated struct CommandSpec: Equatable, Sendable {
    var subcommands: [SubcommandInfo] = []
    var flags: [FlagInfo] = []
}

nonisolated struct ProcessEntry: Equatable, Sendable {
    let pid: Int
    let name: String
}

nonisolated struct ShellSymbol: Equatable, Sendable {
    nonisolated enum Kind: Sendable {
        case executable
        case alias
        case function
        case builtin
        case keyword
    }

    let name: String
    let kind: Kind
    let detail: String?
}

nonisolated enum CommandLookup: Equatable, Sendable {
    case executable
    case builtin
    case alias
    case function
    case keyword
    case missing
    case unknown
}

nonisolated protocol CompletionEnvironment: Sendable {
    var homeDirectory: String { get }
    var variables: [String: String] { get }
    func commandSymbols() -> [ShellSymbol]
    func commandsLoaded() -> Bool
    func isExecutable(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
    func directoryEntries(atPath path: String) -> [DirectoryEntry]?
    func gitRefs(in directory: String) -> GitRefs?
    func flags(forCommand command: String) -> [FlagInfo]
    func lookupCommand(_ name: String, directory: String) -> CommandLookup
    func readText(atPath path: String) -> String?
    func processes() -> [ProcessEntry]
    func dockerObjects() -> DockerObjects
    func cliListing(_ invocation: CLIInvocation) -> [String]
    func awsIndexPath() -> String?
    func commandSpec(forCommand command: String) -> CommandSpec
    func shortcuts(in directory: String) -> [Shortcut]
    func sshHosts() -> [SSHHost]
}

nonisolated extension CompletionEnvironment {
    func readText(atPath path: String) -> String? { nil }

    func processes() -> [ProcessEntry] { [] }

    func dockerObjects() -> DockerObjects { DockerObjects() }

    func cliListing(_ invocation: CLIInvocation) -> [String] { [] }

    func awsIndexPath() -> String? { AWSCompletionIndex.locate(self) }

    func shortcuts(in directory: String) -> [Shortcut] { [] }

    func sshHosts() -> [SSHHost] { [] }

    func commandSpec(forCommand command: String) -> CommandSpec {
        CommandSpec(subcommands: [], flags: flags(forCommand: command))
    }

    func resolve(path: String, directory: String) -> String {
        if path.hasPrefix("~/") { return homeDirectory + path.dropFirst() }
        if path == "~" { return homeDirectory }
        if path.hasPrefix("/") { return path }
        return directory + "/" + path
    }

    func lookupCommand(_ name: String, directory: String) -> CommandLookup {
        if name.contains("/") || name.hasPrefix("~") {
            return isExecutable(atPath: resolve(path: name, directory: directory)) ? .executable : .missing
        }
        return Self.lookupKind(name, in: commandSymbols(), loaded: commandsLoaded())
    }

    static func lookupKind(_ name: String, in symbols: [ShellSymbol], loaded: Bool) -> CommandLookup {
        if let symbol = symbols.first(where: { $0.name == name }) {
            return CommandLookup(symbol.kind)
        }
        return loaded ? .missing : .unknown
    }

    func aliasTarget(of command: String) -> String? {
        guard let symbol = commandSymbols().first(where: { $0.name == command && $0.kind == .alias }),
              let value = symbol.detail
        else { return nil }
        let first = value.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
        guard let first, first != command, !first.contains("=") else { return nil }
        return first
    }
}

nonisolated extension CommandLookup {
    init(_ kind: ShellSymbol.Kind) {
        switch kind {
        case .executable: self = .executable
        case .alias: self = .alias
        case .function: self = .function
        case .builtin: self = .builtin
        case .keyword: self = .keyword
        }
    }
}

extension Notification.Name {
    nonisolated static let completionEnvironmentChanged = Notification.Name("TurmCompletionEnvironmentChanged")
}
