import Foundation
import SwiftTerm
import TurmCore

final class BlockGraphicsHost: GraphicsHost {
    unowned let emulator: BlockEmulator
    private let screens = ScreenBuffers<Buffer>()

    init(emulator: BlockEmulator) {
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
            scale: Double(BlockEmulator.backingScale)
        )
    }

    var allowsLocalMedia: Bool {
        emulator.remoteName == nil
    }

    func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(byteArray: Array(bytes))
    }

    func reply(_ bytes: [UInt8]) {
        emulator.onResponse(bytes[...])
    }

    func placeholderCells(rows: Range<Int>, buffer: GraphicsBuffer) -> [GraphicsCell] {
        terminal.placeholderCells(rows: rows, of: buffer, screens: screens)
    }

    /// Records the active buffer, so the main screen can still be read once a program switches away from it.
    func noteBuffer() {
        screens.note(terminal)
    }
}
