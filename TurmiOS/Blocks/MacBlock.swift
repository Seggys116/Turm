import Foundation
import Observation
import SwiftTerm
import TurmCore

@Observable
final class MacBlock: Identifiable {
    private static let refreshDelay: Duration = .milliseconds(60)

    let id: UUID
    let command: String
    let location: String
    let directory: String
    let git: CompanionGit?
    let host: String?
    private(set) var connectedTo: String?
    private(set) var exitCode: Int32?
    private(set) var isRunning: Bool
    private(set) var duration: TimeInterval?
    private(set) var output: NSAttributedString
    private(set) var revision = 0
    private(set) var progress: Terminal.ProgressReport?

    @ObservationIgnored private var emulator: MacBlockEmulator?
    @ObservationIgnored private var started: Date?
    @ObservationIgnored private var refresh: Task<Void, Never>?

    init(summary: BlockSummary, columns: Int = 80, rows: Int = 24) {
        id = summary.id
        command = summary.command
        location = summary.location
        directory = summary.directory
        git = summary.git
        host = summary.host
        connectedTo = summary.connectedTo
        exitCode = summary.exitCode
        duration = summary.duration
        isRunning = false
        if let styled = summary.styled, !styled.isEmpty {
            let emulator = MacBlockEmulator(cols: columns, rows: rows)
            emulator.feed([UInt8](styled))
            output = emulator.render()
        } else {
            output = BlockStyle.plain(Self.trimmed(summary.text))
        }
    }

    init(
        id: UUID, command: String, location: String, directory: String, git: CompanionGit?, host: String?,
        columns: Int, rows: Int, resumed: Bool = false, respond: (([UInt8]) -> Void)? = nil
    ) {
        self.id = id
        self.command = command
        self.location = location
        self.directory = directory
        self.git = git
        self.host = host
        connectedTo = nil
        isRunning = true
        output = NSAttributedString()
        started = resumed ? nil : Date()
        let emulator = MacBlockEmulator(cols: columns, rows: rows)
        emulator.onProgress = { [weak self] report in self?.progress = report }
        emulator.onResponse = respond
        self.emulator = emulator
    }

    var hasOutput: Bool { output.length > 0 }
    var plainOutput: String { output.string }
    var failed: Bool { (exitCode ?? 0) != 0 }
    var isAlternate: Bool { emulator?.isAlternate ?? false }
    var kittyFlags: Int { emulator?.terminal.keyboardEnhancementFlags.rawValue ?? 0 }

    func append(_ bytes: [UInt8]) {
        guard let emulator else { return }
        emulator.feed(bytes)
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func resize(columns: Int, rows: Int) {
        guard let emulator else { return }
        emulator.resize(cols: columns, rows: rows)
        refreshNow()
    }

    func finish(exitCode: Int32?) {
        guard isRunning else { return }
        refreshNow()
        self.exitCode = exitCode
        isRunning = false
        progress = nil
        if let started { duration = Date().timeIntervalSince(started) }
        emulator = nil
    }

    func markConnected(to target: String) {
        connectedTo = target
    }

    private func refreshNow() {
        refresh?.cancel()
        refresh = nil
        guard let emulator, !emulator.isAlternate else { return }
        output = emulator.render()
        revision += 1
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: seconds < 1 ? "%.3fs" : "%.2fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        if minutes < 60 {
            return String(format: "%dm %.2fs", minutes, rest)
        }
        return String(format: "%dh %dm %.0fs", minutes / 60, minutes % 60, rest)
    }

    private static func trimmed(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
