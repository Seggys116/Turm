import CoreGraphics
import Foundation

nonisolated struct KittyKey: Hashable {
    let imageID: UInt32
    let placementID: UInt32
}

struct KittyDeleteContext {
    let cursorRow: Int
    let cursorColumn: Int
    let screenTop: Int
    let screenRows: Int
    let numbers: [UInt32: UInt32]
    let virtualKeys: Set<KittyKey>
}

enum KittyGeometry {
    static let maxChainDepth = 16

    static func grid(
        pixels: CGSize, columns: Int, rows: Int, cell: (width: Int, height: Int), offset: CGSize
    ) -> (columns: Int, rows: Int) {
        if columns > 0, rows > 0 { return (columns, rows) }
        guard cell.width > 0, cell.height > 0, pixels.width > 0, pixels.height > 0 else {
            return (max(columns, 1), max(rows, 1))
        }
        var width = pixels.width
        var height = pixels.height
        if columns > 0 {
            width = CGFloat(columns * cell.width)
            height = width * pixels.height / pixels.width
        } else if rows > 0 {
            height = CGFloat(rows * cell.height)
            width = height * pixels.width / pixels.height
        }
        let cols = Int(ceil((width + offset.width) / CGFloat(cell.width)))
        let lines = Int(ceil((height + offset.height) / CGFloat(cell.height)))
        return (max(cols, 1), max(lines, 1))
    }

    static func clampedOffset(_ x: Int, _ y: Int, cell: (width: Int, height: Int)) -> CGSize {
        CGSize(
            width: max(0, min(x, max(cell.width - 1, 0))),
            height: max(0, min(y, max(cell.height - 1, 0)))
        )
    }
}

extension Array where Element == InlineImage {
    private func node(_ imageID: UInt32, _ placementID: UInt32, excluding id: UUID) -> InlineImage? {
        first { $0.fromKitty && $0.kittyID == imageID && ($0.placementID ?? 0) == placementID && $0.id != id }
    }

    func origin(
        of image: InlineImage, virtual: [KittyKey: (row: Int, column: Int)] = [:]
    ) -> (row: Int, column: Int)? {
        var row = 0
        var column = 0
        var current = image
        var depth = 0
        while let parent = current.parent {
            guard depth < KittyGeometry.maxChainDepth else { return nil }
            row += parent.rows
            column += parent.columns
            guard let next = node(parent.imageID, parent.placementID, excluding: current.id) else {
                guard let base = virtual[KittyKey(imageID: parent.imageID, placementID: parent.placementID)] else {
                    return nil
                }
                return (row + base.row, column + base.column)
            }
            current = next
            depth += 1
        }
        return (row + current.anchor, column + current.column)
    }

    func chainDepth(from imageID: UInt32, _ placementID: UInt32, replacing key: (UInt32?, UInt32)) -> Int? {
        var depth = 0
        var target: (UInt32, UInt32) = (imageID, placementID)
        while true {
            if key.0 != nil, target.0 == key.0, target.1 == key.1 { return nil }
            guard let next = first(where: {
                $0.fromKitty && $0.kittyID == target.0 && ($0.placementID ?? 0) == target.1
            }) else { return depth }
            depth += 1
            guard let parent = next.parent else { return depth }
            target = (parent.imageID, parent.placementID)
            if depth > KittyGeometry.maxChainDepth { return depth }
        }
    }

    func hasPlacement(_ imageID: UInt32, _ placementID: UInt32) -> Bool {
        contains { $0.fromKitty && $0.kittyID == imageID && ($0.placementID ?? 0) == placementID }
    }

    mutating func removeOrphans(keeping virtual: Set<KittyKey> = []) {
        var changed = true
        while changed {
            changed = false
            for index in indices.reversed() {
                guard let parent = self[index].parent else { continue }
                let key = KittyKey(imageID: parent.imageID, placementID: parent.placementID)
                if node(parent.imageID, parent.placementID, excluding: self[index].id) == nil, !virtual.contains(key) {
                    remove(at: index)
                    changed = true
                }
            }
        }
    }

    mutating func applyKittyDelete(_ command: KittyCommand, context: KittyDeleteContext) {
        let mode = String(command.deleteTarget ?? "a").lowercased()
        let snapshot = self
        let column = (command.x ?? 0) - 1
        let screenRow = context.screenTop + (command.y ?? 0) - 1

        func intersects(_ image: InlineImage, column: Int? = nil, row: Int? = nil) -> Bool {
            guard let origin = snapshot.origin(of: image) else { return false }
            let rows = origin.row..<(origin.row + Swift.max(image.rowSpan, 1))
            let columns = origin.column..<(origin.column + Swift.max(image.columnSpan, 1))
            return (column.map { columns.contains($0) } ?? true) && (row.map { rows.contains($0) } ?? true)
        }
        func byID(_ image: InlineImage, _ id: UInt32?) -> Bool {
            guard let id, image.kittyID == id else { return false }
            return command.placementID.map { image.placementID == $0 } ?? true
        }

        let doomed: (InlineImage) -> Bool
        switch mode {
        case "a":
            doomed = { image in
                guard let origin = snapshot.origin(of: image) else { return false }
                let bottom = origin.row + Swift.max(image.rowSpan, 1)
                return bottom > context.screenTop && origin.row < context.screenTop + context.screenRows
            }
        case "i":
            doomed = { byID($0, command.imageID) }
        case "n":
            doomed = { byID($0, command.imageNumber.flatMap { context.numbers[$0] }) }
        case "c":
            doomed = { intersects($0, column: context.cursorColumn, row: context.cursorRow) }
        case "p":
            doomed = { intersects($0, column: column, row: screenRow) }
        case "q":
            doomed = { $0.zIndex == command.zIndex && intersects($0, column: column, row: screenRow) }
        case "x":
            doomed = { intersects($0, column: column) }
        case "y":
            doomed = { intersects($0, row: screenRow) }
        case "z":
            doomed = { $0.zIndex == command.zIndex }
        case "r":
            let low = command.x ?? 0
            let high = command.y ?? 0
            doomed = { image in
                guard let id = image.kittyID else { return false }
                return Int(id) >= low && Int(id) <= high
            }
        default:
            return
        }
        let survivors = filter { !($0.fromKitty && doomed($0)) }
        self = survivors
        removeOrphans(keeping: context.virtualKeys)
    }
}
