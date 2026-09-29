import AppKit
import Foundation
import SwiftTerm

struct KittyPlaceholderCell {
    let row: Int
    let column: Int
    let imageID: UInt32
    let placementID: UInt32
    let partRow: Int
    let partColumn: Int
    let msb: Int
    let background: NSColor?
}

enum KittyPlaceholders {
    static let base: UInt32 = 0x10EEEE

    static func isPlaceholder(_ character: Character) -> Bool {
        character.unicodeScalars.first?.value == base
    }

    static func decode(
        _ character: Character, attribute: Attribute, row: Int, column: Int,
        previous: (cell: KittyPlaceholderCell, attribute: Attribute)?
    ) -> KittyPlaceholderCell? {
        guard isPlaceholder(character) else { return nil }
        let marks = character.unicodeScalars.dropFirst().compactMap { KittyDiacritics.index[$0.value] }
        let explicitMsb = marks.count > 2 ? marks[2] : nil
        var msb = explicitMsb ?? 0
        let adjacent = previous.map {
            $0.cell.row == row && $0.cell.column == column - 1
                && $0.attribute.fg == attribute.fg && $0.attribute.underlineColor == attribute.underlineColor
        } ?? false
        var partRow = 0
        var partColumn = 0
        switch marks.count {
        case 0:
            if adjacent, let previous {
                partRow = previous.cell.partRow
                partColumn = previous.cell.partColumn + 1
                msb = previous.cell.msb
            }
        case 1:
            partRow = marks[0]
            if adjacent, let previous, previous.cell.partRow == partRow {
                partColumn = previous.cell.partColumn + 1
                msb = previous.cell.msb
            }
        case 2:
            partRow = marks[0]
            partColumn = marks[1]
            if adjacent, let previous, previous.cell.partRow == partRow, previous.cell.partColumn + 1 == partColumn {
                msb = previous.cell.msb
            }
        default:
            partRow = marks[0]
            partColumn = marks[1]
        }
        return KittyPlaceholderCell(
            row: row, column: column,
            imageID: identifier(attribute.fg) | UInt32(min(msb, 255)) << 24,
            placementID: attribute.underlineColor.map { identifier($0) } ?? 0,
            partRow: partRow, partColumn: partColumn, msb: msb,
            background: TerminalPalette.attributes(attribute).appKit.backgroundColor
        )
    }

    private static func identifier(_ color: Attribute.Color) -> UInt32 {
        switch color {
        case .ansi256(let code): return UInt32(code)
        case .trueColor(let red, let green, let blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        case .defaultColor, .defaultInvertedColor: return 0
        }
    }

    static func tiles(
        of cells: [KittyPlaceholderCell], placements: [InlineImage]
    ) -> (tiles: [InlineImage], origins: [KittyKey: (row: Int, column: Int)]) {
        var tiles: [InlineImage] = []
        var origins: [KittyKey: (row: Int, column: Int)] = [:]
        var last: (cell: KittyPlaceholderCell, key: KittyKey)?
        for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            guard let placement = placements.first(where: { $0.kittyID == cell.imageID && ($0.placementID ?? 0) == cell.placementID })
                ?? (cell.placementID == 0 ? placements.first { $0.kittyID == cell.imageID } : nil),
                cell.partRow < placement.rowSpan, cell.partColumn < placement.columnSpan
            else { continue }
            let key = KittyKey(imageID: cell.imageID, placementID: placement.placementID ?? 0)
            let known = origins[key] ?? (cell.row, cell.column)
            origins[key] = (min(known.row, cell.row), min(known.column, cell.column))
            if let previous = last, previous.key == key, previous.cell.row == cell.row,
               previous.cell.column + 1 == cell.column, previous.cell.partRow == cell.partRow,
               previous.cell.partColumn + 1 == cell.partColumn, previous.cell.background == cell.background,
               var tile = tiles.popLast() {
                tile.columnSpan += 1
                tiles.append(tile)
            } else {
                var tile = placement
                tile.anchor = cell.row
                tile.column = cell.column
                tile.columnSpan = 1
                tile.rowSpan = 1
                tile.background = cell.background
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

extension AttributedString {
    var hasPlaceholders: Bool {
        characters.contains { KittyPlaceholders.isPlaceholder($0) }
    }

    func maskingPlaceholders() -> AttributedString {
        var result = AttributedString()
        var index = startIndex
        while index < endIndex {
            let next = self.index(afterCharacter: index)
            let piece = self[index..<next]
            if KittyPlaceholders.isPlaceholder(self.characters[index]) {
                result.append(AttributedString(" ", attributes: piece.runs.first?.attributes ?? AttributeContainer()))
            } else {
                result.append(AttributedString(piece))
            }
            index = next
        }
        return result
    }
}
