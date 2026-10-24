import Foundation

public nonisolated enum ShellKind: String, Codable, Sendable, Equatable, CaseIterable {
    case zsh, bash, fish
}

public nonisolated struct SavedFrame: Codable, Sendable, Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public nonisolated enum SavedSplitAxis: String, Codable, Sendable, Equatable {
    case horizontal, vertical
}

public nonisolated indirect enum SavedPaneNode: Codable, Sendable, Equatable {
    case leaf(UUID)
    case split(id: UUID, axis: SavedSplitAxis, ratio: Double, first: SavedPaneNode, second: SavedPaneNode)

    public static let minimumRatio = 0.1
    public static let maximumRatio = 0.9

    public var leaves: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, _, let first, let second):
            return first.leaves + second.leaves
        }
    }

    public func normalized() -> SavedPaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let first, let second):
            let clamped = min(max(ratio, Self.minimumRatio), Self.maximumRatio)
            return .split(
                id: id,
                axis: axis,
                ratio: clamped,
                first: first.normalized(),
                second: second.normalized()
            )
        }
    }
}

public nonisolated enum DiffScope: Codable, Sendable, Equatable {
    case unstaged
    case staged
    case commit(String)
}

public nonisolated enum DiffLayout: String, Codable, Sendable, Equatable {
    case unified, sideBySide
}

public nonisolated struct SavedShell: Codable, Sendable, Equatable {
    public var directory: String
    public var shell: ShellKind
    public var history: [String]
    public var sshHostID: UUID?
    /// The folder the local shell was in before it connected. Nil for a shell that was never remote.
    public var localDirectory: String?
    /// `user@hostname:port` for a remote that is not a saved host.
    public var remoteTarget: String?

    public init(
        directory: String,
        shell: ShellKind,
        history: [String],
        sshHostID: UUID? = nil,
        localDirectory: String? = nil,
        remoteTarget: String? = nil
    ) {
        self.directory = directory
        self.shell = shell
        self.history = history
        self.sshHostID = sshHostID
        self.localDirectory = localDirectory
        self.remoteTarget = remoteTarget
    }

    private enum CodingKeys: String, CodingKey {
        case directory, shell, history, sshHostID, localDirectory, remoteTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decode(String.self, forKey: .directory)
        shell = try container.decode(ShellKind.self, forKey: .shell)
        history = try container.decode([String].self, forKey: .history)
        sshHostID = try container.decodeIfPresent(UUID.self, forKey: .sshHostID)
        localDirectory = try container.decodeIfPresent(String.self, forKey: .localDirectory)
        remoteTarget = try container.decodeIfPresent(String.self, forKey: .remoteTarget)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directory, forKey: .directory)
        try container.encode(shell, forKey: .shell)
        try container.encode(history, forKey: .history)
        try container.encodeIfPresent(sshHostID, forKey: .sshHostID)
        try container.encodeIfPresent(localDirectory, forKey: .localDirectory)
        try container.encodeIfPresent(remoteTarget, forKey: .remoteTarget)
    }
}

public nonisolated struct SavedDiff: Codable, Sendable, Equatable {
    public var directory: String
    public var scope: DiffScope
    public var layout: DiffLayout
    public var sshHostID: UUID?

    public init(directory: String, scope: DiffScope, layout: DiffLayout, sshHostID: UUID? = nil) {
        self.directory = directory
        self.scope = scope
        self.layout = layout
        self.sshHostID = sshHostID
    }
}

public nonisolated enum SavedPaneContent: Codable, Sendable, Equatable {
    case shell(SavedShell)
    case diff(SavedDiff)
}

public nonisolated struct SavedPane: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var content: SavedPaneContent
    public var showsFiles: Bool

    public init(id: UUID, content: SavedPaneContent, showsFiles: Bool = false) {
        self.id = id
        self.content = content
        self.showsFiles = showsFiles
    }
}

public nonisolated struct SavedTab: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String?
    public var layout: SavedPaneNode
    public var focusedPane: UUID

    public init(id: UUID, title: String?, layout: SavedPaneNode, focusedPane: UUID) {
        self.id = id
        self.title = title
        self.layout = layout
        self.focusedPane = focusedPane
    }
}

public nonisolated struct SavedWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var frame: SavedFrame?
    public var tabs: [SavedTab]
    public var activeTabID: UUID
    public var panes: [SavedPane]

    public init(id: UUID, frame: SavedFrame?, tabs: [SavedTab], activeTabID: UUID, panes: [SavedPane]) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.panes = panes
    }
}

public nonisolated struct SavedBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var command: String
    public var directory: String
    public var gitBranch: String?
    public var host: String?
    public var exitCode: Int32?
    public var duration: Double?
    public var output: String

    public init(
        id: UUID,
        command: String,
        directory: String,
        gitBranch: String? = nil,
        host: String? = nil,
        exitCode: Int32? = nil,
        duration: Double? = nil,
        output: String
    ) {
        self.id = id
        self.command = command
        self.directory = directory
        self.gitBranch = gitBranch
        self.host = host
        self.exitCode = exitCode
        self.duration = duration
        self.output = output
    }
}

public nonisolated struct SavedSpace: Codable, Sendable, Equatable, Identifiable {
    public static let temporaryName = "Tmp"
    public static let temporarySymbol = "clock"

    public var id: UUID
    public var name: String
    public var symbol: String
    public var session: SavedWindow
    public var isTemporary: Bool

    public init(id: UUID, name: String, symbol: String, session: SavedWindow, isTemporary: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.session = session
        self.isTemporary = isTemporary
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, session, isTemporary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        session = try container.decode(SavedWindow.self, forKey: .session)
        isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(session, forKey: .session)
        try container.encode(isTemporary, forKey: .isTemporary)
    }

    public static let symbols = ["terminal", "folder", "hammer", "leaf", "star", "book.closed", "cube", "globe"]

    public static func symbol(at index: Int) -> String {
        symbols[index % symbols.count]
    }
}

public nonisolated struct WorkspaceDocument: Codable, Sendable, Equatable {
    public var windows: [SavedWindow]
    public var keyWindowID: UUID?
    public var spaces: [SavedSpace]

    public init(windows: [SavedWindow], keyWindowID: UUID?, spaces: [SavedSpace] = []) {
        self.windows = windows
        self.keyWindowID = keyWindowID
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case windows, keyWindowID, spaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([SavedWindow].self, forKey: .windows)
        keyWindowID = try container.decodeIfPresent(UUID.self, forKey: .keyWindowID)
        spaces = try container.decodeIfPresent([SavedSpace].self, forKey: .spaces) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(keyWindowID, forKey: .keyWindowID)
        try container.encode(spaces, forKey: .spaces)
    }

    public func removingWindow(_ id: UUID) -> WorkspaceDocument {
        WorkspaceDocument(
            windows: windows.filter { $0.id != id },
            keyWindowID: keyWindowID == id ? nil : keyWindowID,
            spaces: spaces.filter { $0.id != id && $0.session.id != id }
        )
    }

    /// Temp is a scratch space. Its shells are not part of the layout that comes back on the next launch.
    public func discardingTemporarySpaces() -> WorkspaceDocument {
        let temporaryIDs = Set(spaces.filter(\.isTemporary).flatMap { [$0.id, $0.session.id] })
        guard !temporaryIDs.isEmpty else { return self }
        let keptSpaces = spaces.filter { !$0.isTemporary }
        let keptWindows = windows.filter { !temporaryIDs.contains($0.id) }
        let key: UUID?
        if let keyWindowID, temporaryIDs.contains(keyWindowID) {
            key = keptSpaces.first?.id ?? keptWindows.first?.id
        } else {
            key = keyWindowID
        }
        return WorkspaceDocument(windows: keptWindows, keyWindowID: key, spaces: keptSpaces)
    }

    /// Named spaces when the file has them, otherwise one space for each saved window.
    public var spaceCatalog: [SavedSpace] {
        if !spaces.isEmpty { return spaces }
        return windows.enumerated().map { offset, window in
            SavedSpace(
                id: window.id,
                name: Self.derivedSpaceName(for: window, index: offset),
                symbol: SavedSpace.symbol(at: offset),
                session: window
            )
        }
    }

    public func space(forKey id: UUID?) -> SavedSpace? {
        let catalog = spaceCatalog
        if let id, let match = catalog.first(where: { $0.id == id || $0.session.id == id }) {
            return match
        }
        return catalog.first
    }

    private static func derivedSpaceName(for window: SavedWindow, index: Int) -> String {
        if let title = window.tabs.first?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "Space \(index + 1)"
    }
}

public nonisolated struct PhoneSession: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        case mac(sessionID: UUID, macID: UUID)
        case ssh(hostID: UUID)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public nonisolated struct PhoneSpace: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var sessions: [PhoneSession]
    public var isTemporary: Bool

    public init(id: UUID, name: String, symbol: String, sessions: [PhoneSession], isTemporary: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.sessions = sessions
        self.isTemporary = isTemporary
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, sessions, isTemporary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        sessions = try container.decode([PhoneSession].self, forKey: .sessions)
        isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(isTemporary, forKey: .isTemporary)
    }
}

public nonisolated struct PhoneWorkspace: Codable, Sendable, Equatable {
    public var sessions: [PhoneSession]
    public var spaces: [PhoneSpace]
    public var activeSpaceID: UUID?

    public init(sessions: [PhoneSession], spaces: [PhoneSpace] = [], activeSpaceID: UUID? = nil) {
        self.sessions = sessions
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, spaces, activeSpaceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([PhoneSession].self, forKey: .sessions)
        spaces = try container.decodeIfPresent([PhoneSpace].self, forKey: .spaces) ?? []
        activeSpaceID = try container.decodeIfPresent(UUID.self, forKey: .activeSpaceID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(spaces, forKey: .spaces)
        try container.encodeIfPresent(activeSpaceID, forKey: .activeSpaceID)
    }
}

public nonisolated enum BlockArchive {
    public static let maxBlocks = 200
    public static let maxOutputBytes = 8 * 1024 * 1024
    public static let maxHistory = 2000

    public static func retain(_ blocks: [SavedBlock]) -> [SavedBlock] {
        var result = Array(blocks.suffix(maxBlocks))
        var totalBytes = result.reduce(0) { $0 + $1.output.utf8.count }
        var index = 0
        while totalBytes > maxOutputBytes && index < result.count {
            let bytes = result[index].output.utf8.count
            if bytes > 0 {
                result[index].output = ""
                totalBytes -= bytes
            }
            index += 1
        }
        return result
    }

    public static func cappedHistory(_ commands: [String]) -> [String] {
        Array(commands.suffix(maxHistory))
    }
}

public nonisolated enum WorkingDirectory {
    public static func nearestExisting(_ path: String, exists: (String) -> Bool) -> (path: String, missing: Bool) {
        if exists(path) { return (path, false) }
        var current = (path as NSString).deletingLastPathComponent
        while true {
            if exists(current) { return (current, true) }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return ("/", true) }
            current = parent
        }
    }
}

public nonisolated enum RestoreLaunch: Sendable, Equatable {
    public static func decide(restoreEnabled: Bool, skipOnce: Bool) -> (restore: Bool, clearSkipOnce: Bool) {
        if skipOnce { return (restore: false, clearSkipOnce: true) }
        return (restore: restoreEnabled, clearSkipOnce: false)
    }
}

public nonisolated struct TrailingDebounce: Sendable, Equatable {
    public var delay: TimeInterval
    private var fireTime: Date?

    public init(delay: TimeInterval = 0.4) {
        self.delay = delay
        self.fireTime = nil
    }

    public mutating func note(at now: Date) {
        fireTime = now.addingTimeInterval(delay)
    }

    public mutating func consumeIfDue(at now: Date) -> Bool {
        guard let fire = fireTime, now >= fire else { return false }
        fireTime = nil
        return true
    }
}
