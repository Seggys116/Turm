import Foundation

public struct KittyPlaceholderCell: Equatable, Sendable {
    public let row: Int
    public let column: Int
    public let imageID: UInt32
    public let placementID: UInt32
    public let partRow: Int
    public let partColumn: Int
    public let msb: Int
    public let foreground: GraphicsColor
    public let underline: GraphicsColor
    public let background: GraphicsColor

    public init(
        row: Int, column: Int, imageID: UInt32, placementID: UInt32, partRow: Int, partColumn: Int, msb: Int,
        foreground: GraphicsColor, underline: GraphicsColor, background: GraphicsColor
    ) {
        self.row = row
        self.column = column
        self.imageID = imageID
        self.placementID = placementID
        self.partRow = partRow
        self.partColumn = partColumn
        self.msb = msb
        self.foreground = foreground
        self.underline = underline
        self.background = background
    }
}

public enum KittyPlaceholders {
    public nonisolated static let base: UInt32 = 0x10EEEE

    public nonisolated static func isPlaceholder(_ character: Character) -> Bool {
        character.unicodeScalars.first?.value == base
    }

    public static func decode(_ cell: GraphicsCell, previous: KittyPlaceholderCell?) -> KittyPlaceholderCell? {
        guard isPlaceholder(cell.character) else { return nil }
        let row = cell.point.row
        let column = cell.point.column
        let marks = cell.character.unicodeScalars.dropFirst().compactMap { KittyDiacritics.index[$0.value] }
        let explicitMsb = marks.count > 2 ? marks[2] : nil
        var msb = explicitMsb ?? 0
        let adjacent = previous.map {
            $0.row == row && $0.column == column - 1 && $0.foreground == cell.foreground && $0.underline == cell.underline
        } ?? false
        var partRow = 0
        var partColumn = 0
        switch marks.count {
        case 0:
            if adjacent, let previous {
                partRow = previous.partRow
                partColumn = previous.partColumn + 1
                msb = previous.msb
            }
        case 1:
            partRow = marks[0]
            if adjacent, let previous, previous.partRow == partRow {
                partColumn = previous.partColumn + 1
                msb = previous.msb
            }
        case 2:
            partRow = marks[0]
            partColumn = marks[1]
            if adjacent, let previous, previous.partRow == partRow, previous.partColumn + 1 == partColumn {
                msb = previous.msb
            }
        default:
            partRow = marks[0]
            partColumn = marks[1]
        }
        return KittyPlaceholderCell(
            row: row, column: column,
            imageID: identifier(cell.foreground) | UInt32(min(msb, 255)) << 24,
            placementID: identifier(cell.underline),
            partRow: partRow, partColumn: partColumn, msb: msb,
            foreground: cell.foreground, underline: cell.underline, background: cell.background
        )
    }

    public static func decode(_ cells: [GraphicsCell]) -> [KittyPlaceholderCell] {
        var result: [KittyPlaceholderCell] = []
        var previous: KittyPlaceholderCell?
        for cell in cells {
            guard let decoded = decode(cell, previous: previous) else { continue }
            result.append(decoded)
            previous = decoded
        }
        return result
    }

    private nonisolated static func identifier(_ color: GraphicsColor) -> UInt32 {
        switch color {
        case .indexed(let code): return UInt32(code)
        case .rgb(let red, let green, let blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        case .none: return 0
        }
    }

    public static func tiles(
        of cells: [KittyPlaceholderCell], placements: [GraphicsPlacement]
    ) -> (tiles: [GraphicsPlacement], origins: [KittyKey: GridPoint]) {
        var tiles: [GraphicsPlacement] = []
        var origins: [KittyKey: GridPoint] = [:]
        var last: (cell: KittyPlaceholderCell, key: KittyKey)?
        for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            guard let placement = placements.first(where: { $0.kittyID == cell.imageID && ($0.placementID ?? 0) == cell.placementID })
                ?? (cell.placementID == 0 ? placements.first { $0.kittyID == cell.imageID } : nil),
                cell.partRow < placement.rowSpan, cell.partColumn < placement.columnSpan
            else { continue }
            let key = KittyKey(imageID: cell.imageID, placementID: placement.placementID ?? 0)
            let known = origins[key] ?? GridPoint(row: cell.row, column: cell.column)
            origins[key] = GridPoint(row: min(known.row, cell.row), column: min(known.column, cell.column))
            if let previous = last, previous.key == key, previous.cell.row == cell.row,
               previous.cell.column + 1 == cell.column, previous.cell.partRow == cell.partRow,
               previous.cell.partColumn + 1 == cell.partColumn, previous.cell.background == cell.background,
               var tile = tiles.popLast() {
                tile.columnSpan += 1
                tiles.append(tile)
            } else {
                var tile = placement
                tile.origin = GridPoint(row: cell.row, column: cell.column)
                tile.columnSpan = 1
                tile.rowSpan = 1
                tile.tile = KittyTile(
                    columns: placement.columnSpan, rows: placement.rowSpan,
                    partColumn: cell.partColumn, partRow: cell.partRow
                )
                tiles.append(tile)
            }
            last = (cell, key)
        }
        return (tiles, origins)
    }
}
