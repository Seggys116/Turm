import Foundation

public nonisolated enum Companion {
    public static let defaultPort: UInt16 = 7337
    public static let serviceType = "_turm._tcp"
    public static let maxFrame = 4 * 1024 * 1024
}

public nonisolated enum CompanionErrorCode {
    public static let unauthorized = "unauthorized"
    public static let notFound = "notFound"
    public static let notReady = "notReady"
    public static let failed = "failed"
    public static let busy = "busy"
    public static let malformed = "malformed"
}

public nonisolated enum CompanionPhase: String, Codable, Sendable, Equatable {
    case ready
    case running
}

public nonisolated enum CompanionActivity: Codable, Sendable, Equatable {
    case inactive
    case working
    case progress(percent: Double)
    case succeeded
    case failed
}

public nonisolated struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var location: String
    public var phase: CompanionPhase
    public var activity: CompanionActivity
    public var remoteLabel: String?
    public var windowTitle: String?
    public var branch: String?
    public var directory: String?

    public init(
        id: UUID, title: String, location: String, phase: CompanionPhase, activity: CompanionActivity = .inactive,
        remoteLabel: String? = nil, windowTitle: String? = nil, branch: String? = nil, directory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.phase = phase
        self.activity = activity
        self.remoteLabel = remoteLabel
        self.windowTitle = windowTitle
        self.branch = branch
        self.directory = directory
    }
}

/// The git line of a block header: branch, changed files, lines added and removed.
public nonisolated struct CompanionGit: Codable, Sendable, Equatable {
    public var branch: String
    public var files: Int
    public var added: Int
    public var removed: Int

    public init(branch: String, files: Int, added: Int, removed: Int) {
        self.branch = branch
        self.files = files
        self.added = added
        self.removed = removed
    }

    public var isDirty: Bool { files > 0 }
}

public nonisolated struct BlockSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var command: String
    public var location: String
    public var exitCode: Int32?
    public var text: String
    public var directory: String
    public var git: CompanionGit?
    public var host: String?
    public var connectedTo: String?
    public var duration: Double?
    /// The output as SGR-styled text (see StyledOutput); absent when the sender kept only plain text.
    public var styled: Data?

    public init(
        id: UUID, command: String, location: String, exitCode: Int32?, text: String, directory: String = "",
        git: CompanionGit? = nil, host: String? = nil, connectedTo: String? = nil, duration: Double? = nil, styled: Data? = nil
    ) {
        self.styled = styled
        self.id = id
        self.command = command
        self.location = location
        self.exitCode = exitCode
        self.text = text
        self.directory = directory
        self.git = git
        self.host = host
        self.connectedTo = connectedTo
        self.duration = duration
    }
}

public nonisolated struct RunningBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var command: String
    public var location: String
    public var bytes: Data
    public var directory: String
    public var git: CompanionGit?
    public var host: String?

    public init(
        id: UUID, command: String, location: String, bytes: Data, directory: String = "", git: CompanionGit? = nil, host: String? = nil
    ) {
        self.id = id
        self.command = command
        self.location = location
        self.bytes = bytes
        self.directory = directory
        self.git = git
        self.host = host
    }
}

public nonisolated enum CompanionSessionEvent: Sendable, Equatable {
    case blockStarted(blockID: UUID, command: String, location: String)
    case output(blockID: UUID, bytes: Data)
    case blockFinished(blockID: UUID, exitCode: Int32?)
    case phase(CompanionPhase, directory: String)
    case notice(text: String)
    case title(text: String)
    case terminated
}

public nonisolated enum CompanionMessage: Codable, Sendable, Equatable {
    case pairBegin(deviceID: UUID, name: String, commitment: Data)
    case pairKey(macID: UUID, macName: String, publicKey: Data)
    case pairReveal(publicKey: Data, nonce: Data, confirmation: Data)
    case pairDone(confirmation: Data)

    case hello(version: CompanionVersion, deviceID: UUID, name: String, proof: Data)
    case ping
    case listSessions
    case attach(id: UUID)
    case detach(id: UUID)
    case submit(id: UUID, text: String)
    case input(id: UUID, bytes: Data)
    case interrupt(id: UUID)
    case resize(id: UUID, cols: Int, rows: Int)
    case create(directory: String?, command: String?)
    case close(id: UUID, force: Bool)
    case directoryShortcut(path: String)
    case commandShortcut(command: String)
    case listShortcuts
    case saveShortcut(Shortcut)
    case removeShortcut(id: UUID)
    case listBranches(id: UUID)
    case switchBranch(id: UUID, name: String)
    case revealInFinder(path: String)

    case welcome(version: CompanionVersion, macName: String)
    case incompatible(version: CompanionVersion)
    case addresses(hosts: [String], port: UInt16)
    case pong
    case sessions([SessionSummary])
    case sessionChanged(SessionSummary)
    case sessionClosed(id: UUID)
    case snapshot(id: UUID, cols: Int, rows: Int, history: [BlockSummary], running: RunningBlock?)
    case blockStarted(id: UUID, blockID: UUID, command: String, location: String, directory: String, git: CompanionGit?, host: String?)
    case output(id: UUID, blockID: UUID, bytes: Data)
    case blockFinished(id: UUID, blockID: UUID, exitCode: Int32?)
    case phase(id: UUID, phase: CompanionPhase, directory: String)
    case title(id: UUID, text: String)
    case confirmClose(id: UUID, message: String)
    case directoryShortcutInfo(path: String, existing: Shortcut?, draft: Shortcut)
    case commandShortcutInfo(command: String, existing: Shortcut?, draft: Shortcut)
    case shortcuts([Shortcut])
    case branches(id: UUID, names: [String], current: String?)
    case branchSwitched(id: UUID, name: String, failure: String?)
    case ok(request: String)
    case error(code: String, text: String)
}

extension CompanionMessage {
    // raw values are the wire keys, so a kind is named exactly like its case
    public nonisolated enum Kind: String, CaseIterable, Sendable {
        case pairBegin
        case pairKey
        case pairReveal
        case pairDone
        case hello
        case ping
        case listSessions
        case attach
        case detach
        case submit
        case input
        case interrupt
        case resize
        case create
        case close
        case directoryShortcut
        case commandShortcut
        case listShortcuts
        case saveShortcut
        case removeShortcut
        case listBranches
        case switchBranch
        case revealInFinder
        case welcome
        case incompatible
        case addresses
        case pong
        case sessions
        case sessionChanged
        case sessionClosed
        case snapshot
        case blockStarted
        case output
        case blockFinished
        case phase
        case title
        case confirmClose
        case directoryShortcutInfo
        case commandShortcutInfo
        case shortcuts
        case branches
        case branchSwitched
        case ok
        case error

        // a peer lacking any of these cannot run a session at all
        public var isEssential: Bool {
            switch self {
            case .hello, .ping, .listSessions, .attach, .detach, .submit, .input, .interrupt, .welcome, .incompatible, .pong, .sessions, .sessionChanged, .sessionClosed, .snapshot, .blockStarted, .output, .blockFinished, .phase, .ok, .error: true
            case .pairBegin, .pairKey, .pairReveal, .pairDone, .resize, .create, .close, .directoryShortcut, .commandShortcut, .listShortcuts, .saveShortcut, .removeShortcut, .listBranches, .switchBranch, .revealInFinder, .title, .confirmClose, .directoryShortcutInfo, .commandShortcutInfo, .shortcuts, .branches, .branchSwitched, .addresses: false
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .pairBegin: .pairBegin
        case .pairKey: .pairKey
        case .pairReveal: .pairReveal
        case .pairDone: .pairDone
        case .hello: .hello
        case .ping: .ping
        case .listSessions: .listSessions
        case .attach: .attach
        case .detach: .detach
        case .submit: .submit
        case .input: .input
        case .interrupt: .interrupt
        case .resize: .resize
        case .create: .create
        case .close: .close
        case .directoryShortcut: .directoryShortcut
        case .commandShortcut: .commandShortcut
        case .listShortcuts: .listShortcuts
        case .saveShortcut: .saveShortcut
        case .removeShortcut: .removeShortcut
        case .listBranches: .listBranches
        case .switchBranch: .switchBranch
        case .revealInFinder: .revealInFinder
        case .welcome: .welcome
        case .incompatible: .incompatible
        case .addresses: .addresses
        case .pong: .pong
        case .sessions: .sessions
        case .sessionChanged: .sessionChanged
        case .sessionClosed: .sessionClosed
        case .snapshot: .snapshot
        case .blockStarted: .blockStarted
        case .output: .output
        case .blockFinished: .blockFinished
        case .phase: .phase
        case .title: .title
        case .confirmClose: .confirmClose
        case .directoryShortcutInfo: .directoryShortcutInfo
        case .commandShortcutInfo: .commandShortcutInfo
        case .shortcuts: .shortcuts
        case .branches: .branches
        case .branchSwitched: .branchSwitched
        case .ok: .ok
        case .error: .error
        }
    }
}
