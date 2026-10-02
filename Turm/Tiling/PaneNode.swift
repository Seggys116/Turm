import Foundation

nonisolated struct PaneID: Hashable, Sendable {
    let raw = UUID()
}

enum SplitAxis: Sendable {
    case horizontal
    case vertical
}

nonisolated enum PaneEdge: CaseIterable, Sendable {
    case left
    case right
    case top
    case bottom

    var axis: SplitAxis {
        self == .left || self == .right ? .horizontal : .vertical
    }

    var leads: Bool {
        self == .left || self == .top
    }
}

nonisolated enum DropAnchor: Hashable, Sendable {
    case pane(PaneID)
    case root
}

indirect enum PaneNode: Equatable, Sendable {
    case leaf(PaneID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)

    static let minimumRatio = 0.1
    static let maximumRatio = 0.9

    var leaves: [PaneID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, _, let first, let second):
            return first.leaves + second.leaves
        }
    }

    func contains(_ pane: PaneID) -> Bool {
        leaves.contains(pane)
    }

    func splitting(_ pane: PaneID, axis: SplitAxis, inserting newPane: PaneID) -> PaneNode {
        switch self {
        case .leaf(let id):
            guard id == pane else { return self }
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(id), second: .leaf(newPane))
        case .split(let id, let splitAxis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: splitAxis,
                ratio: ratio,
                first: first.splitting(pane, axis: axis, inserting: newPane),
                second: second.splitting(pane, axis: axis, inserting: newPane)
            )
        }
    }

    func removing(_ pane: PaneID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == pane ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(pane) else { return second }
            guard let newSecond = second.removing(pane) else { return first }
            return .split(id: id, axis: axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    func resizing(split target: UUID, to newRatio: Double) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let first, let second):
            let clamped = min(max(newRatio, Self.minimumRatio), Self.maximumRatio)
            return .split(
                id: id,
                axis: axis,
                ratio: id == target ? clamped : ratio,
                first: first.resizing(split: target, to: newRatio),
                second: second.resizing(split: target, to: newRatio)
            )
        }
    }

    func inserting(_ node: PaneNode, at anchor: DropAnchor, edge: PaneEdge) -> PaneNode {
        switch anchor {
        case .root:
            return Self.wrap(self, with: node, edge: edge)
        case .pane(let target):
            return inserting(node, beside: target, edge: edge)
        }
    }

    private func inserting(_ node: PaneNode, beside target: PaneID, edge: PaneEdge) -> PaneNode {
        switch self {
        case .leaf(let id):
            return id == target ? Self.wrap(self, with: node, edge: edge) : self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.inserting(node, beside: target, edge: edge),
                second: second.inserting(node, beside: target, edge: edge)
            )
        }
    }

    private static func wrap(_ existing: PaneNode, with node: PaneNode, edge: PaneEdge) -> PaneNode {
        .split(id: UUID(), axis: edge.axis, ratio: 0.5, first: edge.leads ? node : existing, second: edge.leads ? existing : node)
    }

    func moving(_ pane: PaneID, to anchor: DropAnchor, edge: PaneEdge) -> PaneNode {
        guard anchor != .pane(pane), contains(pane), let rest = removing(pane) else { return self }
        if case .pane(let target) = anchor, !rest.contains(target) { return self }
        return rest.inserting(.leaf(pane), at: anchor, edge: edge)
    }

    func swapping(_ a: PaneID, _ b: PaneID) -> PaneNode {
        guard a != b, contains(a), contains(b) else { return self }
        return mapLeaves { $0 == a ? b : ($0 == b ? a : $0) }
    }

    private func mapLeaves(_ transform: (PaneID) -> PaneID) -> PaneNode {
        switch self {
        case .leaf(let id):
            return .leaf(transform(id))
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio, first: first.mapLeaves(transform), second: second.mapLeaves(transform))
        }
    }

    func equalized(only target: UUID? = nil) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let first, let second):
            let firstWeight = first.weight(along: axis)
            let even = Double(firstWeight) / Double(firstWeight + second.weight(along: axis))
            let clamped = min(max(even, Self.minimumRatio), Self.maximumRatio)
            return .split(
                id: id,
                axis: axis,
                ratio: target == nil || target == id ? clamped : ratio,
                first: first.equalized(only: target),
                second: second.equalized(only: target)
            )
        }
    }

    private func weight(along axis: SplitAxis) -> Int {
        guard case .split(_, let splitAxis, _, let first, let second) = self, splitAxis == axis else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }
}
