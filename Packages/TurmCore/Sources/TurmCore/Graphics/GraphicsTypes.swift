import CoreGraphics
import Foundation

public struct GridPoint: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public enum GraphicsColor: Hashable, Sendable {
    case none
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct GraphicsCell: Sendable {
    public let point: GridPoint
    public let character: Character
    public let foreground: GraphicsColor
    public let underline: GraphicsColor
    public let background: GraphicsColor

    public init(point: GridPoint, character: Character, foreground: GraphicsColor, underline: GraphicsColor, background: GraphicsColor) {
        self.point = point
        self.character = character
        self.foreground = foreground
        self.underline = underline
        self.background = background
    }
}

public struct GraphicsScreen: Sendable {
    public var columns: Int
    public var rows: Int
    public var top: Int
    public var alternate: Bool
    public var cellWidth: Int
    public var cellHeight: Int
    public var scale: Double

    public init(columns: Int, rows: Int, top: Int, alternate: Bool, cellWidth: Int, cellHeight: Int, scale: Double) {
        self.columns = columns
        self.rows = rows
        self.top = top
        self.alternate = alternate
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scale = scale
    }
}

public protocol GraphicsHost: AnyObject {
    var cursor: GridPoint { get }
    var screen: GraphicsScreen { get }
    var allowsLocalMedia: Bool { get }
    func feedTerminal(_ bytes: ArraySlice<UInt8>)
    func reply(_ bytes: [UInt8])
    func placeholderCells(rows: Range<Int>) -> [GraphicsCell]
}

public struct KittyParent: Equatable, Sendable {
    public let imageID: UInt32
    public let placementID: UInt32
    public let columns: Int
    public let rows: Int

    public init(imageID: UInt32, placementID: UInt32, columns: Int, rows: Int) {
        self.imageID = imageID
        self.placementID = placementID
        self.columns = columns
        self.rows = rows
    }
}

public struct KittyTile: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let partColumn: Int
    public let partRow: Int

    public init(columns: Int, rows: Int, partColumn: Int, partRow: Int) {
        self.columns = columns
        self.rows = rows
        self.partColumn = partColumn
        self.partRow = partRow
    }
}

public enum GraphicsSource {
    case still(CGImage)
    case animated(KittyAnimation)
}

public struct GraphicsPlacement: Identifiable {
    public let id = UUID()
    public var source: GraphicsSource
    public var kittyID: UInt32?
    public var placementID: UInt32?
    public var origin: GridPoint
    public var rowSpan = 0
    public var columnSpan = 0
    public var pixelOffset = CGSize.zero
    public var pixelSize = CGSize.zero
    public var scale: CGFloat = 1
    public var crop: CGRect?
    public var tile: KittyTile?
    public var parent: KittyParent?
    public var zIndex = 0
    public var fromKitty = false
    public var background = GraphicsColor.none

    public init(source: GraphicsSource, origin: GridPoint) {
        self.source = source
        self.origin = origin
    }
}
