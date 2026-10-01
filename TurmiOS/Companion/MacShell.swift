import Foundation
import Observation
import SwiftTerm
import TurmCore

@Observable
final class MacShell {
    private static let blockLimit = 500
    private static let fallbackSize = (cols: 80, rows: 24)

    let id: UUID
    private(set) var phase = CompanionPhase.ready
    private(set) var hasEnded = false
    private(set) var macColumns = 0
    private(set) var macRows = 0
    private(set) var blocks: [MacBlock] = []
    private(set) var fullScreen: TerminalSurface?

    @ObservationIgnored private(set) var originalSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var fitSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var resizedByFullScreen = false
    @ObservationIgnored private var sessions: [WeakSession] = []
    @ObservationIgnored private weak var connection: MacConnection?

    private struct WeakSession {
        weak var session: MacSession?
    }

    init(id: UUID) {
        self.id = id
    }

    var hasContent: Bool { macColumns > 0 }

    var runningBlock: MacBlock? {
        blocks.last { $0.isRunning }
    }

    var commands: [String] {
        var seen = Set<String>()
        return blocks.reversed().compactMap { block in
            block.command.isEmpty || !seen.insert(block.command).inserted ? nil : block.command
        }
    }

    func link(to connection: MacConnection) {
        self.connection = connection
    }

    func add(_ session: MacSession) {
        sessions.removeAll { $0.session == nil }
        sessions.append(WeakSession(session: session))
    }

    func remove(_ session: MacSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
    }

    var isUnused: Bool {
        sessions.allSatisfy { $0.session == nil }
    }

    var fitCount: Int {
        sessions.filter { $0.session?.fitsDevice == true }.count
    }

    func ended() {
        hasEnded = true
        leaveFullScreen(restoring: false)
    }

    func sendInput(_ bytes: Data) {
        guard phase == .running, !bytes.isEmpty else { return }
        connection?.send(.input(id: id, bytes: bytes))
    }

    func fit(cols: Int, rows: Int) {
        guard fullScreen == nil, fitSize?.cols != cols || fitSize?.rows != rows else { return }
        fitSize = (cols, rows)
        runningBlock?.resize(columns: cols, rows: rows)
        connection?.send(.resize(id: id, cols: cols, rows: rows))
    }

    func releaseFit() {
        guard fitCount == 0, fitSize != nil else { return }
        fitSize = nil
        guard macColumns > 0 else { return }
        runningBlock?.resize(columns: macColumns, rows: macRows)
        if let original = originalSize {
            connection?.send(.resize(id: id, cols: original.cols, rows: original.rows))
        }
    }

    func handle(_ message: CompanionMessage) {
        switch message {
        case .snapshot(_, let cols, let rows, let history, let running):
            render(cols: cols, rows: rows, history: history, running: running)
        case .blockStarted(_, let blockID, let command, let location, let directory, let git, let host):
            begin(id: blockID, command: command, location: location, directory: directory, git: git, host: host)
        case .output(_, let blockID, let bytes):
            write(bytes, to: blockID)
        case .blockFinished(_, let blockID, let exitCode):
            finish(id: blockID, exitCode: exitCode)
        case .phase(_, let newPhase, _):
            phase = newPhase
        default:
            break
        }
    }

    private var emulationSize: (cols: Int, rows: Int) {
        if let fitSize { return fitSize }
        return macColumns >= 2 && macRows >= 2 ? (macColumns, macRows) : Self.fallbackSize
    }

    private func render(cols: Int, rows: Int, history: [BlockSummary], running: RunningBlock?) {
        leaveFullScreen(restoring: false)
        macColumns = cols
        macRows = rows
        if originalSize == nil || fitCount == 0 { originalSize = (cols, rows) }
        let size = emulationSize
        blocks = history.map { MacBlock(summary: $0, columns: size.cols, rows: size.rows) }
        if let running {
            let block = MacBlock(
                id: running.id, command: running.command, location: running.location, directory: running.directory,
                git: running.git, host: running.host, columns: size.cols, rows: size.rows, resumed: true
            )
            blocks.append(block)
            deliver(running.bytes, to: block)
            phase = .running
        } else {
            phase = .ready
        }
        trimBlocks()
    }

    private func begin(id: UUID, command: String, location: String, directory: String, git: CompanionGit?, host: String?) {
        guard !blocks.contains(where: { $0.id == id }) else { return }
        if let previous = runningBlock { finish(id: previous.id, exitCode: nil) }
        let size = emulationSize
        blocks.append(MacBlock(
            id: id, command: command, location: location, directory: directory, git: git, host: host,
            columns: size.cols, rows: size.rows
        ))
        trimBlocks()
        if !command.isEmpty { phase = .running }
    }

    private func write(_ bytes: Data, to id: UUID) {
        guard !bytes.isEmpty, let block = blocks.last(where: { $0.id == id }) ?? runningBlock, block.isRunning else { return }
        deliver(bytes, to: block)
    }

    private func finish(id: UUID, exitCode: Int32?) {
        guard let block = blocks.last(where: { $0.id == id }), block.isRunning else { return }
        block.finish(exitCode: exitCode)
        leaveFullScreen(restoring: true)
    }

    private func trimBlocks() {
        if blocks.count > Self.blockLimit { blocks.removeFirst(blocks.count - Self.blockLimit) }
    }

    private func deliver(_ bytes: Data, to block: MacBlock) {
        let chunk = [UInt8](bytes)
        block.append(chunk)
        if !block.isAlternate {
            leaveFullScreen(restoring: true)
        } else if let fullScreen {
            fullScreen.feed(chunk[...])
        } else {
            enterFullScreen(replaying: chunk)
        }
    }

    private func enterFullScreen(replaying chunk: [UInt8]) {
        let surface = TerminalSurface()
        if macColumns >= 2, macRows >= 2 { surface.view.resize(cols: macColumns, rows: macRows) }
        surface.feed(chunk[...])
        surface.onInput = { [weak self] bytes in self?.sendInput(Data(bytes)) }
        surface.onResize = { [weak self] cols, rows in
            guard let self, cols >= 2, rows >= 2 else { return }
            resizedByFullScreen = true
            connection?.send(.resize(id: id, cols: cols, rows: rows))
        }
        fullScreen = surface
    }

    private func leaveFullScreen(restoring: Bool) {
        guard fullScreen != nil else { return }
        fullScreen = nil
        let resized = resizedByFullScreen
        resizedByFullScreen = false
        guard restoring, resized else { return }
        if let original = originalSize {
            connection?.send(.resize(id: id, cols: original.cols, rows: original.rows))
        }
        sessions.forEach { $0.session?.applyFit() }
    }
}
