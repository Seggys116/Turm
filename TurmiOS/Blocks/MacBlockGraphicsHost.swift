import Foundation
import SwiftTerm
import TurmCore

struct BlockGraphics {
    static let empty = BlockGraphics(placements: [], firstRow: 0, rowStarts: [])

    var placements: [GraphicsPlacement]
    var firstRow: Int
    var rowStarts: [Int]

    var isEmpty: Bool {
        placements.isEmpty
    }
}

final class MacBlockGraphicsHost: GraphicsHost {
    unowned let emulator: MacBlockEmulator
    private let screens = ScreenBuffers<Buffer>()

    init(emulator: MacBlockEmulator) {
        self.emulator = emulator
    }

    private var terminal: Terminal {
        emulator.terminal
    }

    var cursor: GridPoint {
        GridPoint(row: emulator.cursorRow, column: terminal.buffer.x)
    }

    var screen: GraphicsScreen {
        let buffer = terminal.buffer
        let cell = emulator.cellPixels
        return GraphicsScreen(
            columns: terminal.cols, rows: terminal.rows, top: buffer.yDisp + buffer.totalLinesTrimmed,
            alternate: terminal.isCurrentBufferAlternate, cellWidth: cell.width, cellHeight: cell.height,
            scale: Double(emulator.displayScale)
        )
    }

    // the shell runs on another machine, so its paths and shared memory never name anything here
    var allowsLocalMedia: Bool {
        false
    }

    func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(buffer: bytes)
    }

    func reply(_ bytes: [UInt8]) {
        emulator.onResponse?(bytes)
    }

    func placeholderCells(rows: Range<Int>, buffer: GraphicsBuffer) -> [GraphicsCell] {
        terminal.placeholderCells(rows: rows, of: buffer, screens: screens)
    }

    /// Records the active buffer, so the main screen can still be read once a program switches away from it.
    func noteBuffer() {
        screens.note(terminal)
    }
}
