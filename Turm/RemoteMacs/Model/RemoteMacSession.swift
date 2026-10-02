import CoreGraphics
import Foundation
import Observation
import TurmCore

struct RemoteShortcutTarget: Identifiable {
    enum Kind {
        case directory(String)
        case command(String)
    }

    let id = UUID()
    let kind: Kind
}

enum RemoteSessionBanner {
    case progress(String)
    case problem(String, systemImage: String)
    case notice(String)
}

@Observable
final class RemoteMacSession: Identifiable {
    private static let fitDelay: Duration = .milliseconds(250)

    let id: UUID
    let shell: RemoteMacShell
    private(set) var fitsWindow = false
    var editor: RemoteShortcutTarget?
    var showsBranches = false

    @ObservationIgnored private weak var connection: RemoteMacConnection?
    @ObservationIgnored private var viewport = CGSize.zero
    @ObservationIgnored private var fitTask: Task<Void, Never>?

    init(connection: RemoteMacConnection, shell: RemoteMacShell) {
        self.connection = connection
        self.shell = shell
        id = shell.id
        shell.link(to: connection)
        shell.add(self)
    }

    var phase: CompanionPhase { shell.phase }
    var hasEnded: Bool { shell.hasEnded }
    var macColumns: Int { shell.macColumns }
    var macRows: Int { shell.macRows }
    var macName: String { connection?.name ?? "Mac" }
    var link: RemoteMacConnection.State { connection?.state ?? .offline }
    var notice: String? { connection?.notice }
    var summary: SessionSummary? { connection?.summary(of: id) }
    var title: String { summary?.title ?? "Shell" }
    var subtitle: String { macName + (summary.map { "  " + $0.location } ?? "") }
    var location: String { summary?.location ?? shell.blocks.last?.location ?? "" }
    var directory: String { summary?.directory ?? shell.blocks.last?.directory ?? "" }
    var branch: String? { summary?.branch }
    var remoteLabel: String? { summary?.remoteLabel }
    var shortcuts: [Shortcut] { connection?.shortcuts ?? [] }
    var program: RunningProgram? { summary?.program }

    var programActivity: CompanionActivity {
        hasEnded || link != .connected ? .inactive : summary?.activity ?? .inactive
    }

    var blocks: [Block] { shell.blocks }
    var runningBlock: Block? { shell.runningBlock }
    var commands: [String] { shell.commands }
    var fullScreen: AltScreenHost? { shell.fullScreen }
    var acceptsInput: Bool { link == .connected && !hasEnded }
    var isLive: Bool { link == .connected && !hasEnded }
    var isBusy: Bool { isLive && phase == .running }

    var banner: RemoteSessionBanner? {
        if hasEnded { return .problem("This shell was closed on \(macName).", systemImage: "xmark.circle") }
        switch link {
        case .connecting: return .progress("Connecting to \(macName)")
        case .retrying(let reason): return .progress(reason + " Retrying.")
        case .failed(let reason): return .problem(reason, systemImage: "exclamationmark.triangle")
        case .offline: return .problem("Not connected to \(macName).", systemImage: "bolt.slash")
        case .connected: return notice.map(RemoteSessionBanner.notice)
        }
    }

    func directoryShortcut(at path: String) -> Shortcut? {
        shortcuts.first { $0.kind == .directory && $0.value == path }
    }

    func commandShortcut(for command: String) -> Shortcut? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return shortcuts.first { $0.kind == .command && $0.value.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    func perform(_ work: @escaping (RemoteMacConnection) async throws -> Void) {
        guard let connection else { return }
        Task {
            do {
                try await work(connection)
            } catch {
                connection.report((error as? RemoteMacRequestError)?.text ?? error.localizedDescription)
            }
        }
    }

    func reveal(_ path: String) {
        perform { try await $0.revealInFinder(path: path) }
    }

    func removeShortcut(_ shortcut: Shortcut) {
        perform { try await $0.removeShortcut(shortcut.id) }
    }

    func changeDirectory(to path: String) {
        guard phase == .ready else { return }
        submit("cd " + Self.quoted(path))
    }

    func branches() async throws -> (names: [String], current: String?) {
        guard let connection else { throw RemoteMacRequestError(text: "Not connected to \(macName).") }
        return try await connection.branches(of: id)
    }

    func switchBranch(to name: String) async throws -> String? {
        guard let connection else { throw RemoteMacRequestError(text: "Not connected to \(macName).") }
        return try await connection.switchBranch(of: id, to: name)
    }

    func shortcutInfo(for target: RemoteShortcutTarget) async throws -> (existing: Shortcut?, draft: Shortcut) {
        guard let connection else { throw RemoteMacRequestError(text: "Not connected to \(macName).") }
        switch target.kind {
        case .directory(let path): return try await connection.directoryShortcut(path: path)
        case .command(let command): return try await connection.commandShortcut(command: command)
        }
    }

    func save(_ shortcut: Shortcut) async throws {
        guard let connection else { throw RemoteMacRequestError(text: "Not connected to \(macName).") }
        try await connection.saveShortcut(shortcut)
    }

    func remove(_ shortcut: Shortcut) async throws {
        guard let connection else { throw RemoteMacRequestError(text: "Not connected to \(macName).") }
        try await connection.removeShortcut(shortcut.id)
    }

    private static func quoted(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-+@%:,=~")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func close() {
        fitTask?.cancel()
        shell.remove(self)
        if fitsWindow {
            fitsWindow = false
            shell.releaseFit()
        }
        connection?.release(shell)
    }

    func submit(_ text: String) {
        connection?.send(.submit(id: id, text: text))
    }

    func input(_ bytes: Data) {
        shell.sendInput(bytes)
    }

    func interrupt() {
        connection?.send(.interrupt(id: id))
    }

    func dismissNotice() {
        connection?.dismissNotice()
    }

    func setAppearance(dark: Bool) {
        shell.setAppearance(dark: dark)
    }

    func setFitsWindow(_ on: Bool) {
        guard on != fitsWindow else { return }
        fitsWindow = on
        if on { applyFit() } else { shell.releaseFit() }
    }

    // size is the area available to the text, in points
    func setViewport(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        guard fitsWindow else { return }
        fitTask?.cancel()
        fitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fitDelay)
            guard !Task.isCancelled else { return }
            self?.applyFit()
        }
    }

    func applyFit() {
        guard fitsWindow, viewport.width > 0, viewport.height > 0 else { return }
        let cols = Int(viewport.width / TerminalMetrics.cellWidth)
        let rows = Int(viewport.height / TerminalMetrics.lineHeight)
        guard cols >= 2, rows >= 2 else { return }
        shell.fit(cols: cols, rows: rows)
    }
}
