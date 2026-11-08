import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import TurmCore

struct GraphicsLayerPainterTests {
    private static func solid(_ width: Int, _ height: Int, red: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private let geometry = GraphicsLayerPainter.Geometry(top: 10, cellWidth: 8, cellHeight: 16, scale: 2, origin: CGPoint(x: 5, y: 3))

    private func placement(row: Int, column: Int, still: CGImage? = nil) -> GraphicsPlacement {
        GraphicsPlacement(source: .still(still ?? Self.solid(40, 20)), origin: GridPoint(row: row, column: column))
    }

    @Test func positionsAndSizesFromSpans() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 12, column: 3)
        item.columnSpan = 4
        item.rowSpan = 2
        item.pixelOffset = CGSize(width: 4, height: 6)
        item.scale = 2
        painter.update(placements: [item], geometry: geometry)
        #expect(painter.overlay.sublayers?.count == 1)
        #expect(painter.underlay.sublayers == nil)
        let frame = painter.overlay.sublayers![0].frame
        #expect(frame == CGRect(x: 5 + 24 + 2, y: 3 + 32 + 3, width: 32, height: 32))
    }

    @Test func pixelSizeUsedWhenSpansZero() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 10, column: 0)
        item.pixelSize = CGSize(width: 40, height: 20)
        item.scale = 2
        painter.update(placements: [item], geometry: geometry)
        #expect(painter.overlay.sublayers![0].bounds.size == CGSize(width: 20, height: 10))
    }

    @Test func zIndexSplitsLayers() {
        let painter = GraphicsLayerPainter()
        var below = placement(row: 10, column: 0)
        below.zIndex = -3
        var above = placement(row: 11, column: 0)
        above.zIndex = 2
        painter.update(placements: [below, above], geometry: geometry)
        #expect(painter.underlay.sublayers?.count == 1)
        #expect(painter.overlay.sublayers?.count == 1)
        #expect(painter.underlay.sublayers![0].zPosition == -3)
        #expect(painter.overlay.sublayers![0].zPosition == 2)
    }

    @Test func cropSetsContentsRect() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 10, column: 0)
        item.crop = CGRect(x: 10, y: 5, width: 20, height: 10)
        painter.update(placements: [item], geometry: geometry)
        #expect(painter.overlay.sublayers![0].contentsRect == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test func tileSelectsSubRectangle() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 11, column: 2)
        item.columnSpan = 2
        item.rowSpan = 1
        item.tile = KittyTile(columns: 8, rows: 4, partColumn: 2, partRow: 1)
        painter.update(placements: [item], geometry: geometry)
        let layer = painter.overlay.sublayers![0]
        #expect(layer.contentsRect == CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        #expect(layer.bounds.size == CGSize(width: 16, height: 16))
    }

    @Test func tileWithinCrop() {
        let rect = GraphicsLayerPainter.contentsRect(
            crop: CGRect(x: 20, y: 0, width: 20, height: 20), tile: KittyTile(columns: 2, rows: 2, partColumn: 1, partRow: 0),
            columnSpan: 1, pixels: CGSize(width: 40, height: 20)
        )
        #expect(rect == CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    @Test func layersAreReusedAndRemoved() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 10, column: 0)
        item.kittyID = 7
        item.placementID = 1
        painter.update(placements: [item], geometry: geometry)
        let first = painter.overlay.sublayers![0]
        item.origin = GridPoint(row: 11, column: 1)
        painter.update(placements: [item], geometry: geometry)
        #expect(painter.overlay.sublayers?.count == 1)
        #expect(painter.overlay.sublayers![0] === first)
        painter.update(placements: [], geometry: geometry)
        #expect(painter.overlay.sublayers == nil)
    }

    @Test func layerMovesBetweenUnderlayAndOverlay() {
        let painter = GraphicsLayerPainter()
        var item = placement(row: 10, column: 0)
        item.kittyID = 1
        painter.update(placements: [item], geometry: geometry)
        item.zIndex = -1
        painter.update(placements: [item], geometry: geometry)
        #expect(painter.overlay.sublayers == nil)
        #expect(painter.underlay.sublayers?.count == 1)
    }

    @Test func removeAllClearsLayers() {
        let painter = GraphicsLayerPainter()
        painter.update(placements: [placement(row: 10, column: 0), placement(row: 11, column: 0)], geometry: geometry)
        #expect(painter.overlay.sublayers?.count == 2)
        painter.removeAll()
        #expect(painter.overlay.sublayers == nil)
    }

    @Test func animatedContentsFollowClock() {
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let painter = GraphicsLayerPainter(now: { clock.value })
        let first = Self.solid(4, 4, red: 1)
        let second = Self.solid(4, 4, red: 0.5)
        let animation = KittyAnimation(root: first)
        animation.setGap(100, of: 0)
        animation.append(second, gap: 100)
        animation.setState(3, now: clock.value)
        let item = GraphicsPlacement(source: .animated(animation), origin: GridPoint(row: 10, column: 0))
        painter.update(placements: [item], geometry: geometry)
        let layer = painter.overlay.sublayers![0]
        #expect((layer.contents as! CGImage) === animation.frames[0].image)
        clock.value = clock.value.addingTimeInterval(0.15)
        painter.update(placements: [item], geometry: geometry)
        #expect((layer.contents as! CGImage) === animation.frames[1].image)
        painter.removeAll()
    }
}

private final class Box {
    var value: Date
    init(_ value: Date) { self.value = value }
}
