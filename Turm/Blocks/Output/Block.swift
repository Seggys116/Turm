import Foundation
import Observation
import SwiftUI

@Observable
final class Block: Identifiable {
    let id = UUID()
    let command: String
    let usedShortcut: Bool
    let directory: String
    let git: GitStatus?
    let emulator: BlockEmulator
    private(set) var output = ""
    private(set) var segments: [OutputSegment] = []
    private(set) var exitCode: Int32?
    private(set) var duration: Duration?
    private(set) var isRunning = true
    private(set) var revision = 0
    private var rawLog: [UInt8] = []
    private static let rawLogLimit = 2_000_000

    init(command: String, usedShortcut: Bool = false, directory: String, git: GitStatus?, emulator: BlockEmulator) {
        self.command = command
        self.usedShortcut = usedShortcut
        self.directory = directory
        self.git = git
        self.emulator = emulator
    }

    var rawBytes: [UInt8] {
        rawLog
    }

    var plainOutput: String {
        output
    }

    var hasOutput: Bool {
        !segments.isEmpty
    }

    func append(_ bytes: [UInt8]) {
        rawLog.append(contentsOf: bytes)
        if rawLog.count > Self.rawLogLimit {
            rawLog.removeFirst(rawLog.count - Self.rawLogLimit)
        }
        emulator.feed(bytes)
    }

    func refreshOutput() {
        segments = emulator.renderSegments()
        output = segments.plainText
        revision += 1
    }

    func finish(exitCode: Int32?, duration: Duration?) {
        self.exitCode = exitCode
        self.duration = duration
        isRunning = false
        refreshOutput()
        emulator.releaseRenderCache()
        rawLog = []
    }

    var failed: Bool {
        if let exitCode { return exitCode != 0 }
        return false
    }

    static func formatDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
