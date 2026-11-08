import Foundation
import SwiftTerm
import TurmCore

final class BlockGraphicsHost: GraphicsHost {
    unowned let emulator: BlockEmulator

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

    func placeholderCells(rows: Range<Int>) -> [GraphicsCell] {
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed
        let lower = max(rows.lowerBound, trimmed)
        let upper = min(rows.upperBound, trimmed + buffer.yDisp + terminal.rows)
        guard lower < upper else { return [] }
        var cells: [GraphicsCell] = []
        for row in lower..<upper {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            for column in 0..<line.count {
                let data = line[column]
                if data.width == 0 { continue }
                let character = terminal.getCharacter(for: data)
                guard KittyPlaceholders.isPlaceholder(character) else { continue }
                let attribute = data.attribute
                cells.append(GraphicsCell(
                    point: GridPoint(row: row, column: column), character: character,
                    foreground: Self.color(attribute.fg),
                    underline: attribute.underlineColor.map(Self.color) ?? .none,
                    background: Self.color(attribute.style.contains(.inverse) ? attribute.fg : attribute.bg)
                ))
            }
        }
        return cells
    }

    nonisolated static func color(_ value: Attribute.Color) -> GraphicsColor {
        switch value {
        case .ansi256(let code): return .indexed(code)
        case .trueColor(let red, let green, let blue): return .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: return .none
        }
    }
}
