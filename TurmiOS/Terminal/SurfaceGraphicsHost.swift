import Foundation
import SwiftTerm
import TurmCore
import UIKit

final class SurfaceGraphicsHost: GraphicsHost {
    unowned let surface: TerminalSurface
    private let screens = ScreenBuffers<Buffer>()

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    private var terminal: Terminal {
        surface.view.getTerminal()
    }

    var cursor: GridPoint {
        GridPoint(row: screenTop + terminal.buffer.y, column: terminal.buffer.x)
    }

    var screen: GraphicsScreen {
        let cell = surface.cellPoints
        let scale = surface.displayScale
        return GraphicsScreen(
            columns: terminal.cols, rows: terminal.rows, top: screenTop, alternate: terminal.isCurrentBufferAlternate,
            cellWidth: max(Int((cell.width * scale).rounded()), 1), cellHeight: max(Int((cell.height * scale).rounded()), 1),
            scale: Double(scale)
        )
    }

    var allowsLocalMedia: Bool {
        false
    }

    func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        surface.view.feed(byteArray: bytes)
    }

    func reply(_ bytes: [UInt8]) {
        guard !surface.replays, !bytes.isEmpty else { return }
        surface.onInput?(ArraySlice(bytes))
    }

    var screenTop: Int {
        lineEnd - terminal.rows
    }

    var lineEnd: Int {
        let terminal = terminal
        let buffer = terminal.buffer
        var low = buffer.totalLinesTrimmed + buffer.yDisp + terminal.rows - 1
        guard terminal.getScrollInvariantLine(row: low) != nil else {
            return buffer.totalLinesTrimmed + buffer.yDisp + terminal.rows
        }
        var step = 1
        var high = low + step
        while terminal.getScrollInvariantLine(row: high) != nil {
            low = high
            step *= 2
            high = low + step
        }
        while high - low > 1 {
            let middle = (low + high) / 2
            if terminal.getScrollInvariantLine(row: middle) != nil { low = middle } else { high = middle }
        }
        return high
    }

    func placeholderCells(rows: Range<Int>, buffer: GraphicsBuffer) -> [GraphicsCell] {
        terminal.placeholderCells(rows: rows, of: buffer, screens: screens, activeEnd: lineEnd)
    }

    func noteBuffer() {
        screens.note(terminal)
    }
}
