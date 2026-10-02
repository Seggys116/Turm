import CoreGraphics
import Foundation

nonisolated struct PaneLayout: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let id: PaneID
        let frame: CGRect
    }

    struct Divider: Equatable, Sendable {
        let split: UUID
        let axis: SplitAxis
        let bounds: CGRect
        let position: CGFloat

        var available: CGFloat {
            max((axis == .horizontal ? bounds.width : bounds.height) - PaneLayout.dividerThickness, 1)
        }

        var frame: CGRect {
            axis == .horizontal
                ? CGRect(x: bounds.minX + position, y: bounds.minY, width: PaneLayout.dividerThickness, height: bounds.height)
                : CGRect(x: bounds.minX, y: bounds.minY + position, width: bounds.width, height: PaneLayout.dividerThickness)
        }

        func ratio(at point: CGPoint) -> Double {
            Double((axis == .horizontal ? point.x - bounds.minX : point.y - bounds.minY) / available)
        }
    }

    static let dividerThickness: CGFloat = 1
    static let rootBand: CGFloat = 20
    static let swapZone: ClosedRange<CGFloat> = 0.3...0.7

    private(set) var panes: [Pane] = []
    private(set) var dividers: [Divider] = []
    let bounds: CGRect

    init(node: PaneNode, size: CGSize) {
        bounds = CGRect(origin: .zero, size: size)
        place(node, in: bounds)
    }

    func dropTarget(at point: CGPoint, allowsSwap: Bool) -> PaneDrop? {
        guard bounds.contains(point) else { return nil }
        if panes.count > 1 {
            let distances: [(PaneEdge, CGFloat)] = [
                (.left, point.x - bounds.minX), (.right, bounds.maxX - point.x),
                (.top, point.y - bounds.minY), (.bottom, bounds.maxY - point.y),
            ]
            if let (edge, distance) = distances.min(by: { $0.1 < $1.1 }), distance < Self.rootBand {
                return PaneDrop(anchor: .root, edge: edge)
            }
        }
        guard let pane = panes.first(where: { $0.frame.insetBy(dx: -Self.dividerThickness, dy: -Self.dividerThickness).contains(point) })
        else { return nil }
        let frame = pane.frame
        let x = (point.x - frame.minX) / max(frame.width, 1)
        let y = (point.y - frame.minY) / max(frame.height, 1)
        if allowsSwap, Self.swapZone.contains(x), Self.swapZone.contains(y) {
            return PaneDrop(anchor: .pane(pane.id), edge: nil)
        }
        let edges: [(PaneEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = edges.min { $0.1 < $1.1 }!.0
        return PaneDrop(anchor: .pane(pane.id), edge: nearest)
    }

    func previewFrame(for drop: PaneDrop) -> CGRect? {
        let target: CGRect
        switch drop.anchor {
        case .root:
            target = bounds
        case .pane(let id):
            guard let pane = panes.first(where: { $0.id == id }) else { return nil }
            target = pane.frame
        }
        guard let edge = drop.edge else { return target }
        switch edge {
        case .left: return CGRect(x: target.minX, y: target.minY, width: target.width / 2, height: target.height)
        case .right: return CGRect(x: target.midX, y: target.minY, width: target.width / 2, height: target.height)
        case .top: return CGRect(x: target.minX, y: target.minY, width: target.width, height: target.height / 2)
        case .bottom: return CGRect(x: target.minX, y: target.midY, width: target.width, height: target.height / 2)
        }
    }

    private mutating func place(_ node: PaneNode, in rect: CGRect) {
        switch node {
        case .leaf(let id):
            panes.append(Pane(id: id, frame: rect))
        case .split(let id, let axis, let ratio, let first, let second):
            let thickness = Self.dividerThickness
            let length = axis == .horizontal ? rect.width : rect.height
            let firstLength = max(length - thickness, 1) * ratio
            let secondLength = max(length - firstLength - thickness, 0)
            let divider = Divider(split: id, axis: axis, bounds: rect, position: firstLength)
            if axis == .horizontal {
                place(first, in: CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height))
                place(second, in: CGRect(x: rect.minX + firstLength + thickness, y: rect.minY, width: secondLength, height: rect.height))
            } else {
                place(first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength))
                place(second, in: CGRect(x: rect.minX, y: rect.minY + firstLength + thickness, width: rect.width, height: secondLength))
            }
            dividers.append(divider)
        }
    }
}

nonisolated struct PaneDrop: Equatable, Sendable {
    let anchor: DropAnchor
    let edge: PaneEdge?
}
