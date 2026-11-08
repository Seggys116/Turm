import CoreGraphics
import Foundation
import Testing

@testable import TurmCore

private let rowMarks = ["\u{0305}", "\u{030D}", "\u{030E}"]

private func glyph(_ marks: Int...) -> Character {
    let indices = marks.map { rowMarks[$0] }
    return Character("\u{10EEEE}" + indices.joined())
}

private func cell(
    _ row: Int, _ column: Int, _ character: Character, foreground: GraphicsColor = .indexed(42),
    underline: GraphicsColor = .none, background: GraphicsColor = .none
) -> GraphicsCell {
    GraphicsCell(
        point: GridPoint(row: row, column: column), character: character,
        foreground: foreground, underline: underline, background: background
    )
}

private func solidImage(width: Int = 1, height: Int = 1) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func virtualPlacement(
    id: UInt32, placementID: UInt32? = nil, columns: Int, rows: Int, zIndex: Int = 0, crop: CGRect? = nil
) -> GraphicsPlacement {
    var placement = GraphicsPlacement(source: .still(solidImage()), origin: GridPoint(row: 0, column: 0))
    placement.kittyID = id
    placement.placementID = placementID
    placement.fromKitty = true
    placement.columnSpan = columns
    placement.rowSpan = rows
    placement.zIndex = zIndex
    placement.crop = crop
    return placement
}

struct KittyPlaceholderDecodeTests {
    @Test func onlyThePlaceholderScalarDecodes() {
        #expect(KittyPlaceholders.decode(cell(0, 0, "x"), previous: nil) == nil)
        #expect(KittyPlaceholders.decode(cell(0, 0, glyph(0, 0)), previous: nil) != nil)
    }

    @Test func indexedForegroundIsTheImageID() {
        let decoded = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0)), previous: nil)
        #expect(decoded?.imageID == 42)
        #expect(decoded?.placementID == 0)
    }

    @Test func trueColorForegroundIsTheImageID() {
        let decoded = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0), foreground: .rgb(1, 2, 3)), previous: nil)
        #expect(decoded?.imageID == 0x010203)
    }

    @Test func underlineColorIsThePlacementID() {
        let indexed = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0), underline: .indexed(7)), previous: nil)
        let rgb = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0), underline: .rgb(0, 1, 2)), previous: nil)
        #expect(indexed?.placementID == 7)
        #expect(rgb?.placementID == 0x000102)
    }

    @Test func thirdDiacriticIsTheHighByteOfTheImageID() {
        let decoded = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0, 1)), previous: nil)
        #expect(decoded?.msb == 1)
        #expect(decoded?.imageID == UInt32(0x0100002A))
    }

    @Test func partsComeFromTheFirstTwoDiacritics() {
        let decoded = KittyPlaceholders.decode(cell(0, 0, glyph(2, 1)), previous: nil)
        #expect(decoded?.partRow == 2)
        #expect(decoded?.partColumn == 1)
    }

    @Test func bareCellContinuesThePreviousOne() {
        let first = KittyPlaceholders.decode(cell(3, 4, glyph(1, 0, 2)), previous: nil)
        let second = KittyPlaceholders.decode(cell(3, 5, glyph()), previous: first)
        #expect(second?.partRow == 1)
        #expect(second?.partColumn == 1)
        #expect(second?.msb == 2)
        #expect(second?.imageID == UInt32(0x0200002A))
    }

    @Test func rowOnlyCellContinuesWhenTheRowMatches() {
        let first = KittyPlaceholders.decode(cell(0, 0, glyph(1, 0, 1)), previous: nil)
        let same = KittyPlaceholders.decode(cell(0, 1, glyph(1)), previous: first)
        let other = KittyPlaceholders.decode(cell(0, 1, glyph(2)), previous: first)
        #expect(same?.partColumn == 1 && same?.msb == 1)
        #expect(other?.partColumn == 0 && other?.msb == 0)
    }

    @Test func fullyNumberedCellInheritsTheHighByteOnlyWhenConsecutive() {
        let first = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0, 1)), previous: nil)
        let next = KittyPlaceholders.decode(cell(0, 1, glyph(0, 1)), previous: first)
        let gap = KittyPlaceholders.decode(cell(0, 1, glyph(0, 2)), previous: first)
        #expect(next?.msb == 1)
        #expect(gap?.msb == 0)
    }

    @Test func continuationNeedsAdjacencyAndTheSameColours() {
        let first = KittyPlaceholders.decode(cell(0, 0, glyph(0, 0)), previous: nil)
        let apart = KittyPlaceholders.decode(cell(0, 2, glyph()), previous: first)
        let nextRow = KittyPlaceholders.decode(cell(1, 1, glyph()), previous: first)
        let recolored = KittyPlaceholders.decode(cell(0, 1, glyph(), foreground: .indexed(9)), previous: first)
        let underlined = KittyPlaceholders.decode(cell(0, 1, glyph(), underline: .indexed(1)), previous: first)
        for decoded in [apart, nextRow, recolored, underlined] {
            #expect(decoded?.partColumn == 0)
        }
    }

    @Test func listDecodeSkipsOtherCellsAndChainsTheRest() {
        let cells = [cell(0, 0, glyph(0, 0)), cell(0, 1, "x"), cell(0, 2, glyph())]
        let decoded = KittyPlaceholders.decode(cells)
        #expect(decoded.count == 2)
        #expect(decoded[1].partColumn == 0)
        let adjacent = KittyPlaceholders.decode([cell(0, 0, glyph(0, 0)), cell(0, 1, glyph())])
        #expect(adjacent.map(\.partColumn) == [0, 1])
    }
}

struct KittyPlaceholderTileTests {
    private func grid(rows: Int, columns: Int, background: GraphicsColor = .none) -> [KittyPlaceholderCell] {
        var cells: [GraphicsCell] = []
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(cell(row, column, glyph(row, column), background: background))
            }
        }
        return KittyPlaceholders.decode(cells)
    }

    @Test func placeholderCellsBecomeImageTiles() {
        let placement = virtualPlacement(id: 42, columns: 2, rows: 2)
        let result = KittyPlaceholders.tiles(of: grid(rows: 2, columns: 2), placements: [placement])
        #expect(result.tiles.count == 2)
        #expect(result.tiles.map(\.origin.row) == [0, 1])
        #expect(result.tiles.allSatisfy { $0.columnSpan == 2 && $0.rowSpan == 1 && $0.tile?.columns == 2 && $0.tile?.rows == 2 })
        #expect(result.tiles.map { $0.tile?.partRow } == [0, 1])
        #expect(result.tiles.allSatisfy { $0.tile?.partColumn == 0 })
        #expect(result.origins[KittyKey(imageID: 42, placementID: 0)] == GridPoint(row: 0, column: 0))
    }

    @Test func placeholdersWithoutAPlacementProduceNoTiles() {
        let result = KittyPlaceholders.tiles(of: grid(rows: 1, columns: 1), placements: [])
        #expect(result.tiles.isEmpty)
        #expect(result.origins.isEmpty)
    }

    @Test func cellsOutsideThePlacementGridAreSkipped() {
        let placement = virtualPlacement(id: 42, columns: 1, rows: 1)
        let result = KittyPlaceholders.tiles(of: grid(rows: 2, columns: 2), placements: [placement])
        #expect(result.tiles.count == 1)
        #expect(result.tiles[0].columnSpan == 1)
    }

    @Test func tilesCarryTheVirtualZIndex() {
        let placement = virtualPlacement(id: 42, columns: 1, rows: 1, zIndex: -3)
        let result = KittyPlaceholders.tiles(of: grid(rows: 1, columns: 1), placements: [placement])
        #expect(result.tiles.count == 1)
        #expect(result.tiles[0].zIndex == -3)
    }

    @Test func cellsWithDifferentBackgroundsAreNotMerged() {
        let placement = virtualPlacement(id: 42, columns: 2, rows: 1)
        let cells = KittyPlaceholders.decode([
            cell(0, 0, glyph(0, 0), background: .indexed(1)),
            cell(0, 1, glyph(0, 1), background: .indexed(2)),
        ])
        #expect(KittyPlaceholders.tiles(of: cells, placements: [placement]).tiles.count == 2)
    }

    @Test func cropIsCarriedToEveryTile() {
        let crop = CGRect(x: 1, y: 1, width: 2, height: 2)
        let placement = virtualPlacement(id: 42, columns: 2, rows: 2, crop: crop)
        let result = KittyPlaceholders.tiles(of: grid(rows: 2, columns: 2), placements: [placement])
        #expect(result.tiles.count == 2)
        #expect(result.tiles.allSatisfy { $0.crop == crop })
    }

    @Test func placementIDSelectsTheMatchingPlacement() {
        let first = virtualPlacement(id: 42, placementID: 1, columns: 1, rows: 1, zIndex: 1)
        let second = virtualPlacement(id: 42, placementID: 2, columns: 1, rows: 1, zIndex: 2)
        let cells = KittyPlaceholders.decode([cell(0, 0, glyph(0, 0), underline: .indexed(2))])
        let result = KittyPlaceholders.tiles(of: cells, placements: [first, second])
        #expect(result.tiles.map(\.zIndex) == [2])
        #expect(result.origins[KittyKey(imageID: 42, placementID: 2)] == GridPoint(row: 0, column: 0))
    }

    @Test func zeroPlacementIDFallsBackToAnyPlacementOfTheImage() {
        let placement = virtualPlacement(id: 42, placementID: 5, columns: 1, rows: 1)
        let result = KittyPlaceholders.tiles(of: grid(rows: 1, columns: 1), placements: [placement])
        #expect(result.tiles.count == 1)
        #expect(result.origins[KittyKey(imageID: 42, placementID: 5)] != nil)
    }

    @Test func originIsTheTopLeftCellOfThePlaceholderBlock() {
        let placement = virtualPlacement(id: 42, columns: 2, rows: 1)
        let cells = KittyPlaceholders.decode([cell(4, 6, glyph(0, 0)), cell(4, 7, glyph(0, 1))])
        let result = KittyPlaceholders.tiles(of: cells, placements: [placement])
        #expect(result.origins[KittyKey(imageID: 42, placementID: 0)] == GridPoint(row: 4, column: 6))
        #expect(result.tiles[0].origin == GridPoint(row: 4, column: 6))
    }
}

struct GraphicsCellScanTests {
    private struct Slot {
        let character: Character?
        let shade: UInt8
    }

    private func grid(_ placed: [GridPoint: Character]) -> (GridPoint) -> Slot {
        { point in Slot(character: placed[point] ?? " ", shade: UInt8(point.row * 10 + point.column)) }
    }

    @Test func scanKeepsOnlyPlaceholdersWithTheirColours() {
        let read = grid([GridPoint(row: 1, column: 2): glyph(0, 0), GridPoint(row: 1, column: 0): "x"])
        let cells = KittyPlaceholders.scan(
            rows: 0..<3, within: 0..<3, columns: 4, cell: read, character: \.character,
            colors: { (.indexed($0.shade), .rgb(1, 2, 3), .none) }
        )
        #expect(cells.map(\.point) == [GridPoint(row: 1, column: 2)])
        #expect(cells.first?.foreground == .indexed(12))
        #expect(cells.first?.underline == .rgb(1, 2, 3))
        #expect(cells.first?.character == glyph(0, 0))
    }

    @Test func scanStaysInsideTheStoredRows() {
        var read: [GridPoint] = []
        _ = KittyPlaceholders.scan(
            rows: 0..<Int.max, within: 5..<7, columns: 2, cell: { point -> Slot in
                read.append(point)
                return Slot(character: " ", shade: 0)
            }, character: \.character, colors: { _ in (.none, .none, .none) }
        )
        #expect(Set(read.map(\.row)) == [5, 6])
        #expect(read.count == 4)
    }

    @Test func scanSkipsCellsWithoutACharacter() {
        let cells = KittyPlaceholders.scan(
            rows: 0..<1, within: 0..<1, columns: 1, cell: { _ in Slot(character: nil, shade: 0) },
            character: \.character, colors: { _ in (.none, .none, .none) }
        )
        #expect(cells.isEmpty)
    }

    @Test func emptyOverlapScansNothing() {
        let cells = KittyPlaceholders.scan(
            rows: 0..<4, within: 8..<9, columns: 3, cell: { _ -> Slot in Issue.record("read outside the stored rows"); return Slot(character: nil, shade: 0) },
            character: \.character, colors: { _ in (.none, .none, .none) }
        )
        #expect(cells.isEmpty)
    }

    @Test func screenBuffersRememberEachScreen() {
        final class Screen {}
        let buffers = ScreenBuffers<Screen>()
        let normal = Screen()
        let alternate = Screen()
        #expect(buffers[.normal] == nil)
        buffers.note(normal, alternate: false)
        buffers.note(alternate, alternate: true)
        #expect(buffers[.normal] === normal)
        #expect(buffers[.alternate] === alternate)
        let replaced = Screen()
        buffers.note(replaced, alternate: false)
        #expect(buffers[.normal] === replaced)
        #expect(buffers[.alternate] === alternate)
    }
}
