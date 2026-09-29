import AppKit
import CoreGraphics
import Foundation
import SwiftTerm

struct KittyParent: Equatable {
    let imageID: UInt32
    let placementID: UInt32
    let columns: Int
    let rows: Int
}

struct KittyTile: Equatable {
    let columns: Int
    let rows: Int
    let partColumn: Int
    let partRow: Int
}

struct InlineImage: Identifiable {
    let id = UUID()
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

    var naturalSize: CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image.size }
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    func requestedSize(cellWidth: CGFloat, lineHeight: CGFloat) -> CGSize {
        let natural = naturalSize
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let requestedWidth = Self.points(width, cell: cellWidth)
        let requestedHeight = Self.points(height, cell: lineHeight)
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

    private static func points(_ request: ImageSizeRequest, cell: CGFloat) -> CGFloat? {
        switch request {
        case .cells(let count): return CGFloat(count) * cell
        case .pixels(let count): return CGFloat(count)
        case .auto, .percent: return nil
        }
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
