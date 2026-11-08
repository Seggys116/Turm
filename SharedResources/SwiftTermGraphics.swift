import SwiftTerm
import TurmCore

extension Terminal {
    /// Placeholder cells of `buffer`, which need not be the active one; `end` overrides its last stored row.
    func placeholderCells(rows: Range<Int>, in buffer: Buffer, end: Int? = nil) -> [GraphicsCell] {
        let top = buffer.totalLinesTrimmed
        return KittyPlaceholders.scan(
            rows: rows, within: top..<max(end ?? top + buffer.yDisp + self.rows, top), columns: cols,
            cell: { buffer.getChar(atBufferRelative: Position(col: $0.column, row: $0.row - top)) },
            character: { $0.width == 0 ? nil : getCharacter(for: $0) },
            colors: { data in
                let attribute = data.attribute
                return (
                    attribute.fg.graphicsColor, attribute.underlineColor?.graphicsColor ?? .none,
                    (attribute.style.contains(.inverse) ? attribute.fg : attribute.bg).graphicsColor
                )
            }
        )
    }

    /// Placeholder cells of the screen `which`, using the buffer `screens` kept for it while it is hidden;
    /// `activeEnd` overrides the last stored row when `which` is the screen on show.
    func placeholderCells(
        rows: Range<Int>, of which: GraphicsBuffer, screens: ScreenBuffers<Buffer>, activeEnd: Int? = nil
    ) -> [GraphicsCell] {
        screens.note(self)
        guard let source = screens[which] else { return [] }
        return placeholderCells(rows: rows, in: source, end: source === buffer ? activeEnd : nil)
    }
}

extension Terminal {
    /// Line feeds that scroll the screen's text into history with the cursor kept, ahead of a scrollback clear.
    func scrollbackPush(screenTop: Int? = nil) -> [UInt8]? {
        guard !isCurrentBufferAlternate else { return nil }
        let top = screenTop ?? buffer.totalLinesTrimmed + buffer.yDisp
        func blank(_ row: Int) -> Bool {
            guard let line = getScrollInvariantLine(row: top + row) else { return true }
            for column in 0..<line.count {
                let character = getCharacter(for: line[column])
                if character != " " && character != "\u{0}" { return false }
            }
            return true
        }
        var count = rows
        while count > 0, blank(count - 1) { count -= 1 }
        guard count > 0 else { return nil }
        return Array(("\u{1B}7\u{1B}[\(rows);1H" + String(repeating: "\n", count: count) + "\u{1B}8").utf8)
    }
}

extension ScreenBuffers where Buffer == SwiftTerm.Buffer {
    func note(_ terminal: Terminal) {
        note(terminal.buffer, alternate: terminal.isCurrentBufferAlternate)
    }
}

extension Attribute.Color {
    nonisolated var graphicsColor: GraphicsColor {
        switch self {
        case .ansi256(let code): return .indexed(code)
        case .trueColor(let red, let green, let blue): return .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: return .none
        }
    }
}
