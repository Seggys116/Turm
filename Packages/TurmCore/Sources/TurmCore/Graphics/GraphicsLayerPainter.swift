import CoreGraphics
import Foundation
import QuartzCore

public final class GraphicsLayerPainter {
    public struct Geometry: Equatable {
        public var top: Int
        public var cellWidth: CGFloat
        public var cellHeight: CGFloat
        public var scale: CGFloat
        public var origin: CGPoint

        public init(top: Int, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat, origin: CGPoint = .zero) {
            self.top = top
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.scale = scale
            self.origin = origin
        }
    }

    private struct Key: Hashable {
        var kittyID: UInt32?
        var placementID: UInt32?
        var row: Int?
        var column: Int?
        var uuid: UUID?
    }

    private struct Entry {
        let layer: CALayer
        var source: GraphicsSource
        var shown: Int
    }

    public let overlay = CALayer()
    public let underlay = CALayer()
    public var onNeedsFrame: (() -> Void)?

    private let now: () -> Date
    private var entries: [Key: Entry] = [:]
    private var timer: Timer?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
        overlay.masksToBounds = false
        underlay.masksToBounds = false
    }

    isolated deinit {
        timer?.invalidate()
    }

    public func update(placements: [GraphicsPlacement], geometry: Geometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let date = now()
        var kept: [Key: Entry] = [:]
        for placement in placements {
            var key = Self.key(for: placement)
            if kept[key] != nil { key = Key(uuid: placement.id) }
            var entry = entries[key] ?? Entry(layer: Self.makeLayer(), source: placement.source, shown: -1)
            entry.source = placement.source
            configure(&entry, for: placement, geometry: geometry, date: date)
            let parent = placement.zIndex < 0 ? underlay : overlay
            if entry.layer.superlayer !== parent { parent.addSublayer(entry.layer) }
            kept[key] = entry
        }
        for (key, entry) in entries where kept[key] == nil { entry.layer.removeFromSuperlayer() }
        entries = kept
        schedule(after: date)
    }

    public func removeAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries.values { entry.layer.removeFromSuperlayer() }
        entries.removeAll()
        CATransaction.commit()
        timer?.invalidate()
        timer = nil
    }

    private static func key(for placement: GraphicsPlacement) -> Key {
        guard let kittyID = placement.kittyID else { return Key(uuid: placement.id) }
        let tiled = placement.tile != nil
        return Key(
            kittyID: kittyID,
            placementID: placement.placementID,
            row: tiled ? placement.origin.row : nil,
            column: tiled ? placement.origin.column : nil
        )
    }

    private static func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.isOpaque = false
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.masksToBounds = true
        return layer
    }

    private func configure(_ entry: inout Entry, for placement: GraphicsPlacement, geometry: Geometry, date: Date) {
        let layer = entry.layer
        let scale = placement.scale > 0 ? placement.scale : max(geometry.scale, 1)
        let pixels = Self.pixelSize(of: placement.source)
        let tile = placement.tile
        let x = CGFloat(placement.origin.column) * geometry.cellWidth + placement.pixelOffset.width / scale
        let y = CGFloat(placement.origin.row - geometry.top) * geometry.cellHeight + placement.pixelOffset.height / scale

        var width = placement.columnSpan > 0 ? CGFloat(placement.columnSpan) * geometry.cellWidth : placement.pixelSize.width / scale
        var height = placement.rowSpan > 0 ? CGFloat(placement.rowSpan) * geometry.cellHeight : placement.pixelSize.height / scale
        if tile != nil, placement.rowSpan == 0 { height = geometry.cellHeight }
        if width <= 0 { width = pixels.width / scale }
        if height <= 0 { height = pixels.height / scale }

        layer.frame = CGRect(x: geometry.origin.x + x, y: geometry.origin.y + y, width: width, height: height)
        layer.zPosition = CGFloat(placement.zIndex)
        layer.contentsScale = max(geometry.scale, 1)
        layer.contentsRect = Self.contentsRect(crop: placement.crop, tile: tile, columnSpan: placement.columnSpan, pixels: pixels)

        if case .animated(let animation) = placement.source {
            let index = animation.frameIndex(at: date)
            if index != entry.shown || layer.contents == nil {
                layer.contents = animation.frames[index].image
                entry.shown = index
            }
        } else if case .still(let image) = placement.source {
            layer.contents = image
            entry.shown = 0
        }
    }

    private static func pixelSize(of source: GraphicsSource) -> CGSize {
        switch source {
        case .still(let image): CGSize(width: image.width, height: image.height)
        case .animated(let animation): CGSize(width: animation.size.width, height: animation.size.height)
        }
    }

    static func contentsRect(crop: CGRect?, tile: KittyTile?, columnSpan: Int, pixels: CGSize) -> CGRect {
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let crop, pixels.width > 0, pixels.height > 0 {
            rect = CGRect(x: crop.minX / pixels.width, y: crop.minY / pixels.height, width: crop.width / pixels.width, height: crop.height / pixels.height)
                .intersection(rect)
            if rect.isNull || rect.isEmpty { rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
        }
        guard let tile, tile.columns > 0, tile.rows > 0 else { return rect }
        let columns = CGFloat(tile.columns)
        let rows = CGFloat(tile.rows)
        let span = CGFloat(max(columnSpan, 1))
        return CGRect(
            x: rect.minX + rect.width * CGFloat(tile.partColumn) / columns,
            y: rect.minY + rect.height * CGFloat(tile.partRow) / rows,
            width: rect.width * span / columns,
            height: rect.height / rows
        )
    }

    private func animations() -> [KittyAnimation] {
        entries.values.compactMap { entry in
            if case .animated(let animation) = entry.source, animation.frames.count > 1 { return animation }
            return nil
        }
    }

    private func schedule(after date: Date) {
        timer?.invalidate()
        timer = nil
        guard let next = animations().compactMap({ $0.nextChange(after: date) }).min() else { return }
        let fire = Timer(fire: max(next, date.addingTimeInterval(0.001)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }

    private func tick() {
        timer = nil
        let date = now()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, var entry) in entries {
            guard case .animated(let animation) = entry.source else { continue }
            let index = animation.frameIndex(at: date)
            guard index != entry.shown else { continue }
            entry.layer.contents = animation.frames[index].image
            entry.shown = index
            entries[key] = entry
        }
        CATransaction.commit()
        onNeedsFrame?()
        schedule(after: date)
    }
}
