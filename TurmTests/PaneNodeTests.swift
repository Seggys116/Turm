import Foundation
import Testing
@testable import Turm

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func splitIDs(_ node: PaneNode) -> [UUID] {
    switch node {
    case .leaf:
        return []
    case .split(let id, _, _, let first, let second):
        return [id] + splitIDs(first) + splitIDs(second)
    }
}

private func ratioOf(_ target: UUID, in node: PaneNode) -> Double? {
    switch node {
    case .leaf:
        return nil
    case .split(let id, _, let value, let first, let second):
        if id == target { return value }
        return ratioOf(target, in: first) ?? ratioOf(target, in: second)
    }
}

@MainActor
struct PaneNodeTests {
    let a = PaneID()
    let b = PaneID()
    let c = PaneID()
    let d = PaneID()

    @Test func panesHaveDistinctIdentity() {
        #expect(PaneID() != PaneID())
        #expect(a == a)
    }

    @Test func splittingALeafPutsNewPaneSecondWithEvenRatio() {
        let result = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        guard case .split(_, let axis, let ratio, let first, let second) = result else {
            Issue.record("expected a split")
            return
        }
        #expect(axis == .horizontal)
        #expect(ratio == 0.5)
        #expect(first == .leaf(a))
        #expect(second == .leaf(b))
    }

    @Test func splittingAnAbsentPaneChangesNothing() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .vertical, inserting: b)
        #expect(tree.splitting(c, axis: .horizontal, inserting: d) == tree)
    }

    @Test func splittingANestedLeafKeepsTheOtherBranch() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        let result = tree.splitting(b, axis: .vertical, inserting: c)

        guard case .split(let rootID, .horizontal, let rootRatio, let first, let second) = result,
              case .split(_, .vertical, 0.5, .leaf(let x), .leaf(let y)) = second
        else {
            Issue.record("unexpected shape: \(result)")
            return
        }
        guard case .split(let originalID, _, _, _, _) = tree else { return }
        #expect(rootID == originalID)
        #expect(rootRatio == 0.5)
        #expect(first == .leaf(a))
        #expect(x == b)
        #expect(y == c)
    }

    @Test func leavesAreInReadingOrder() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(a, axis: .vertical, inserting: c)
        tree = tree.splitting(b, axis: .vertical, inserting: d)

        #expect(tree.leaves == [a, c, b, d])
    }

    @Test func containsReportsMembership() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        #expect(tree.contains(a))
        #expect(tree.contains(b))
        #expect(!tree.contains(c))
    }

    @Test func removingTheOnlyPaneReturnsNil() {
        #expect(PaneNode.leaf(a).removing(a) == nil)
    }

    @Test func removingAPanePromotesItsSibling() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        #expect(tree.removing(a) == .leaf(b))
        #expect(tree.removing(b) == .leaf(a))
    }

    @Test func removingKeepsOtherSplitIDsAndRatios() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)
        let ids = splitIDs(tree)
        let rootID = ids[0]
        tree = tree.resizing(split: rootID, to: 0.3)

        let result = tree.removing(c)

        #expect(result?.leaves == [a, b])
        #expect(splitIDs(result!) == [rootID])
        #expect(ratioOf(rootID, in: result!) == 0.3)
    }

    @Test func removingAnAbsentPaneIsANoOp() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)

        #expect(tree.removing(d) == tree)
        #expect(PaneNode.leaf(a).removing(d) == .leaf(a))
    }

    @Test func resizingClampsToTheAllowedRange() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        let id = splitIDs(tree)[0]

        #expect(ratioOf(id, in: tree.resizing(split: id, to: 0.0)) == PaneNode.minimumRatio)
        #expect(ratioOf(id, in: tree.resizing(split: id, to: -4)) == PaneNode.minimumRatio)
        #expect(ratioOf(id, in: tree.resizing(split: id, to: 1.0)) == PaneNode.maximumRatio)
        #expect(ratioOf(id, in: tree.resizing(split: id, to: 7)) == PaneNode.maximumRatio)
        #expect(ratioOf(id, in: tree.resizing(split: id, to: 0.25)) == 0.25)
    }

    @Test func resizingOnlyChangesTheTargetedSplit() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)
        let ids = splitIDs(tree)
        let root = ids[0]
        let inner = ids[1]

        let resized = tree.resizing(split: inner, to: 0.7)

        #expect(ratioOf(inner, in: resized) == 0.7)
        #expect(ratioOf(root, in: resized) == 0.5)
        #expect(resized.leaves == tree.leaves)
        #expect(splitIDs(resized) == ids)
    }

    @Test func resizingAnUnknownSplitChangesNothing() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        #expect(tree.resizing(split: UUID(), to: 0.2) == tree)
        #expect(PaneNode.leaf(a).resizing(split: UUID(), to: 0.2) == .leaf(a))
    }

    @Test func randomSplitsAndRemovalsKeepLeavesUniqueAndCounted() {
        var rng = SplitMix64(state: 42)

        for _ in 0..<200 {
            var tree = PaneNode.leaf(PaneID())
            var expected = 1

            for _ in 0..<40 {
                let leaves = tree.leaves
                let target = leaves.randomElement(using: &rng)!

                if Bool.random(using: &rng) || leaves.count == 1 {
                    let axis: SplitAxis = Bool.random(using: &rng) ? .horizontal : .vertical
                    tree = tree.splitting(target, axis: axis, inserting: PaneID())
                    expected += 1
                } else {
                    guard let next = tree.removing(target) else {
                        Issue.record("removal from a multi-pane tree returned nil")
                        return
                    }
                    #expect(!next.contains(target))
                    tree = next
                    expected -= 1
                }

                let now = tree.leaves
                #expect(now.count == expected)
                #expect(Set(now).count == now.count)
                #expect(splitIDs(tree).count == now.count - 1)
                #expect(Set(splitIDs(tree)).count == splitIDs(tree).count)
            }
        }
    }
}
