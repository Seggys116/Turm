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

    private(set) var panes: [Pane] = []
    private(set) var dividers: [Divider] = []

    init(node: PaneNode, size: CGSize) {
        place(node, in: CGRect(origin: .zero, size: size))
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
