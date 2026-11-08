import AppKit
import CoreGraphics
import Foundation
import SwiftTerm
import TurmCore

struct InlineImage: Identifiable {
    var id = UUID()
    let image: NSImage
    let width: ImageSizeRequest
    let height: ImageSizeRequest
    var anchor: Int
    var kittyID: UInt32?
    var fromKitty = false
    var placementID: UInt32?
    var zIndex = 0
    var column = 0
    var rowSpan = 0
    var columnSpan = 0
    var pixelOffset = CGSize.zero
    var pixelSize = CGSize.zero
    var scale: CGFloat = 1
    var parent: KittyParent?
    var animation: KittyAnimation?
    var crop: CGRect?
    var tile: KittyTile?
    var background: NSColor?
    var preserveAspectRatio = true
    var pane = CGSize.zero

    var naturalSize: CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image.size }
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    func requestedSize(cellWidth: CGFloat, lineHeight: CGFloat) -> CGSize {
        let natural = naturalSize
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let requestedWidth = Self.points(width, cell: cellWidth, pane: pane.width)
        let requestedHeight = Self.points(height, cell: lineHeight, pane: pane.height)
        switch (requestedWidth, requestedHeight) {
        case (nil, nil):
            return natural
        case (let w?, nil):
            return CGSize(width: w, height: w * natural.height / natural.width)
        case (nil, let h?):
            return CGSize(width: h * natural.width / natural.height, height: h)
        case (let w?, let h?):
            return CGSize(width: w, height: h)
        }
    }

    private static func points(_ request: ImageSizeRequest, cell: CGFloat, pane: CGFloat) -> CGFloat? {
        switch request {
        case .cells(let count): return CGFloat(count) * cell
        case .pixels(let count): return CGFloat(count)
        case .percent(let count): return pane > 0 ? pane * CGFloat(count) / 100 : nil
        case .auto: return nil
        }
    }
}

extension InlineImage {
    init(placement: GraphicsPlacement, requested: (columns: Int, rows: Int) = (0, 0)) {
        let root: CGImage
        var animation: KittyAnimation?
        switch placement.source {
        case .still(let image):
            root = image
        case .animated(let clip):
            root = clip.frames[0].image
            animation = clip
        }
        let shown = placement.crop.flatMap { root.cropping(to: $0) } ?? root
        self.init(
            image: NSImage(cgImage: shown, size: NSSize(width: shown.width, height: shown.height)),
            width: requested.columns > 0 ? .cells(requested.columns) : .auto,
            height: requested.rows > 0 ? .cells(requested.rows) : .auto,
            anchor: placement.origin.row, kittyID: placement.kittyID, fromKitty: placement.fromKitty
        )
        id = placement.id
        placementID = placement.placementID
        zIndex = placement.zIndex
        column = placement.origin.column
        rowSpan = placement.rowSpan
        columnSpan = placement.columnSpan
        pixelOffset = placement.pixelOffset
        pixelSize = placement.pixelSize
        scale = placement.scale
        parent = placement.parent
        self.animation = animation
        crop = placement.crop
        tile = placement.tile
        background = TerminalPalette.color(placement.background)
    }
}

extension AttributedString {
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

struct ImageStack {
    let start: Int
    let rows: Int
    let lines: [AttributedString]
    let images: [InlineImage]

    var text: AttributedString {
        var joined = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(AttributedString("\n")) }
            joined.append(line)
        }
        return joined
    }
}

enum OutputSegment {
    case text(OutputText)
    case image(InlineImage)
    case stack(ImageStack)
}

extension Array where Element == OutputSegment {
    var plainText: String {
        var parts: [String] = []
        for segment in self {
            switch segment {
            case .text(let text): parts.append(text.string)
            case .stack(let stack): parts.append(stack.lines.map { String($0.characters) }.joined(separator: "\n"))
            case .image: break
            }
        }
        return parts.joined(separator: "\n")
    }

    var isEmpty: Bool {
        allSatisfy { segment in
            if case .text(let text) = segment { return text.isEmpty }
            return false
        }
    }
}
