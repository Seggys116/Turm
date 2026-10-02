import AppKit
import Foundation
import Observation
import TurmCore

@Observable
final class RemoteMacShell {
    private static let blockLimit = 500
    private static let fallbackSize = (cols: 80, rows: 24)
    private static let refreshDelay: Duration = .milliseconds(60)

    let id: UUID
    private(set) var phase = CompanionPhase.ready
    private(set) var hasEnded = false
    private(set) var macColumns = 0
    private(set) var macRows = 0
    private(set) var blocks: [Block] = []
    private(set) var fullScreen: AltScreenHost?

    @ObservationIgnored private(set) var originalSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var fitSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var resizedByFullScreen = false
    @ObservationIgnored private var sessions: [WeakSession] = []
    @ObservationIgnored private weak var connection: RemoteMacConnection?
    @ObservationIgnored private var remoteBlocks: [UUID: Block] = [:]
    @ObservationIgnored private var startTimes: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua

    private struct WeakSession {
        weak var session: RemoteMacSession?
    }

    init(id: UUID) {
        self.id = id
    }

    var hasContent: Bool { macColumns > 0 }

    var runningBlock: Block? {
        blocks.last { $0.isRunning }
    }

    var commands: [String] {
        var seen = Set<String>()
        return blocks.reversed().compactMap { block in
            block.command.isEmpty || !seen.insert(block.command).inserted ? nil : block.command
        }
    }

    func link(to connection: RemoteMacConnection) {
        self.connection = connection
    }

    func add(_ session: RemoteMacSession) {
        sessions.removeAll { $0.session == nil }
        sessions.append(WeakSession(session: session))
    }

    func remove(_ session: RemoteMacSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
    }

    var isUnused: Bool {
        sessions.allSatisfy { $0.session == nil }
    }

    var fitCount: Int {
        sessions.filter { $0.session?.fitsWindow == true }.count
    }

    func ended() {
        hasEnded = true
        leaveFullScreen(restoring: false)
    }

    func sendInput(_ bytes: Data) {
        guard phase == .running, !bytes.isEmpty else { return }
        connection?.send(.input(id: id, bytes: bytes))
    }

    func setAppearance(dark: Bool) {
        isDark = dark
        runningBlock?.emulator.apply(dark: dark)
        fullScreen?.apply(dark: dark)
    }

    func fit(cols: Int, rows: Int) {
        guard fullScreen == nil, fitSize?.cols != cols || fitSize?.rows != rows else { return }
        fitSize = (cols, rows)
        resizeRunningBlock(columns: cols, rows: rows)
        connection?.send(.resize(id: id, cols: cols, rows: rows))
    }

    func releaseFit() {
        guard fitCount == 0, fitSize != nil else { return }
        fitSize = nil
        guard macColumns > 0 else { return }
        resizeRunningBlock(columns: macColumns, rows: macRows)
        if let original = originalSize {
            connection?.send(.resize(id: id, cols: original.cols, rows: original.rows))
        }
    }

    func handle(_ message: CompanionMessage) {
        switch message {
        case .snapshot(_, let cols, let rows, let history, let running):
            render(cols: cols, rows: rows, history: history, running: running)
        case .blockStarted(_, let blockID, let command, _, let directory, let git, let host):
            begin(id: blockID, command: command, directory: directory, git: git, host: host)
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

    private func resizeRunningBlock(columns: Int, rows: Int) {
        guard let block = runningBlock else { return }
        block.emulator.resize(cols: columns, rows: rows)
        block.refreshOutput()
    }

    private func makeBlock(command: String, directory: String, git: CompanionGit?, host: String?, size: (cols: Int, rows: Int)) -> Block {
        let emulator = BlockEmulator(cols: size.cols, rows: size.rows)
        emulator.apply(dark: isDark)
        let status = git.map { GitStatus(branch: $0.branch, files: $0.files, added: $0.added, removed: $0.removed) }
        return Block(command: command, directory: directory, git: status, host: host, emulator: emulator)
    }

    private func render(cols: Int, rows: Int, history: [BlockSummary], running: RunningBlock?) {
        leaveFullScreen(restoring: false)
        refresh?.cancel()
        refresh = nil
        macColumns = cols
        macRows = rows
        if originalSize == nil || fitCount == 0 { originalSize = (cols, rows) }
        let size = emulationSize
        remoteBlocks = [:]
        startTimes = [:]
        blocks = history.map { summary in
            let block = makeBlock(command: summary.command, directory: summary.directory, git: summary.git, host: summary.host, size: size)
            if let styled = summary.styled, !styled.isEmpty {
                block.append([UInt8](styled))
            } else {
                block.append(Array(Self.terminalText(summary.text).utf8))
            }
            if let target = summary.connectedTo { block.markConnected(to: target) }
            block.finish(exitCode: summary.exitCode, duration: summary.duration.map { .seconds($0) })
            remoteBlocks[summary.id] = block
            return block
        }
        if let running {
            let block = makeBlock(command: running.command, directory: running.directory, git: running.git, host: running.host, size: size)
            block.emulator.tracksCursor = true
            blocks.append(block)
            remoteBlocks[running.id] = block
            deliver(running.bytes, to: block)
            block.refreshOutput()
            phase = .running
        } else {
            phase = .ready
        }
        trimBlocks()
    }

    private func begin(id: UUID, command: String, directory: String, git: CompanionGit?, host: String?) {
        guard remoteBlocks[id] == nil else { return }
        if let previous = runningBlock, let previousID = remoteBlocks.first(where: { $0.value === previous })?.key {
            finish(id: previousID, exitCode: nil)
        }
        let block = makeBlock(command: command, directory: directory, git: git, host: host, size: emulationSize)
        block.emulator.tracksCursor = true
        blocks.append(block)
        remoteBlocks[id] = block
        startTimes[id] = .now
        trimBlocks()
        if !command.isEmpty { phase = .running }
    }

    private func write(_ bytes: Data, to id: UUID) {
        guard !bytes.isEmpty, let block = remoteBlocks[id] ?? runningBlock, block.isRunning else { return }
        deliver(bytes, to: block)
    }

    private func finish(id: UUID, exitCode: Int32?) {
        guard let block = remoteBlocks[id], block.isRunning else { return }
        let elapsed = startTimes.removeValue(forKey: id).map { ContinuousClock.now - $0 }
        block.finish(exitCode: exitCode, duration: elapsed)
        leaveFullScreen(restoring: true)
    }

    private func trimBlocks() {
        guard blocks.count > Self.blockLimit else { return }
        blocks.removeFirst(blocks.count - Self.blockLimit)
        let kept = Set(blocks.map(ObjectIdentifier.init))
        remoteBlocks = remoteBlocks.filter { kept.contains(ObjectIdentifier($0.value)) }
        startTimes = startTimes.filter { remoteBlocks[$0.key] != nil }
    }

    private func deliver(_ bytes: Data, to block: Block) {
        let chunk = [UInt8](bytes)
        block.append(chunk)
        if !block.emulator.isAlternate {
            leaveFullScreen(restoring: true)
            scheduleRefresh()
        } else if let fullScreen {
            fullScreen.feed(chunk)
        } else {
            enterFullScreen(for: block)
        }
    }

    private func scheduleRefresh() {
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled, let self else { return }
            refresh = nil
            runningBlock?.refreshOutput()
        }
    }

    private func enterFullScreen(for block: Block) {
        let columns = macColumns >= 2 && macRows >= 2 ? macColumns : Self.fallbackSize.cols
        let rows = macColumns >= 2 && macRows >= 2 ? macRows : Self.fallbackSize.rows
        let host = AltScreenHost(cols: columns, rows: rows)
        host.apply(dark: isDark)
        host.replay(block.rawBytes)
        host.onInput = { [weak self] bytes in self?.sendInput(Data(bytes)) }
        host.onResize = { [weak self] cols, rows in
            guard let self, cols >= 2, rows >= 2 else { return }
            resizedByFullScreen = true
            connection?.send(.resize(id: id, cols: cols, rows: rows))
        }
        fullScreen = host
    }

    private func leaveFullScreen(restoring: Bool) {
        guard fullScreen != nil else { return }
        fullScreen = nil
        let resized = resizedByFullScreen
        resizedByFullScreen = false
        guard restoring, resized else { return }
        if fitCount > 0, let fit = fitSize {
            connection?.send(.resize(id: id, cols: fit.cols, rows: fit.rows))
        } else if let original = originalSize {
            connection?.send(.resize(id: id, cols: original.cols, rows: original.rows))
        }
        sessions.forEach { $0.session?.applyFit() }
    }

    private static func terminalText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        return result.replacingOccurrences(of: "\n", with: "\r\n")
    }
}
