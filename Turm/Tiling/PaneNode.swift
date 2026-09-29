import Foundation

struct PaneID: Hashable, Sendable {
    let raw = UUID()
}

enum SplitAxis: Sendable {
    case horizontal
    case vertical
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
}
