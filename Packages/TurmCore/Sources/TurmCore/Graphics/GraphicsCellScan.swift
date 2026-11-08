import Foundation

/// Keeps each screen's buffer while it is on show, for terminals that hide the inactive one.
public final class ScreenBuffers<Buffer: AnyObject> {
    public private(set) var normal: Buffer?
    public private(set) var alternate: Buffer?

    public init() {}

    public func note(_ buffer: Buffer, alternate isAlternate: Bool) {
        if isAlternate {
            alternate = buffer
        } else {
            normal = buffer
        }
    }

    public subscript(buffer: GraphicsBuffer) -> Buffer? {
        buffer == .alternate ? alternate : normal
    }
}

extension KittyPlaceholders {
    /// Placeholder cells of `rows` that lie in `stored`, read one grid cell at a time through the closures.
    public static func scan<Cell>(
        rows: Range<Int>,
        within stored: Range<Int>,
        columns: Int,
        cell: (GridPoint) -> Cell,
        character: (Cell) -> Character?,
        colors: (Cell) -> (foreground: GraphicsColor, underline: GraphicsColor, background: GraphicsColor)
    ) -> [GraphicsCell] {
        let lower = max(rows.lowerBound, stored.lowerBound)
        let upper = min(rows.upperBound, stored.upperBound)
        guard lower < upper, columns > 0 else { return [] }
        var cells: [GraphicsCell] = []
        for row in lower..<upper {
            for column in 0..<columns {
                let point = GridPoint(row: row, column: column)
                let data = cell(point)
                guard let shown = character(data), isPlaceholder(shown) else { continue }
                let color = colors(data)
                cells.append(GraphicsCell(
                    point: point, character: shown, foreground: color.foreground, underline: color.underline,
                    background: color.background
                ))
            }
        }
        return cells
    }
}
