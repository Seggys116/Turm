import CoreGraphics
import Foundation
import Testing
@testable import Turm

private func ratios(_ node: PaneNode) -> [Double] {
    guard case .split(_, _, let ratio, let first, let second) = node else { return [] }
    return [ratio] + ratios(first) + ratios(second)
}

private func splitIDs(_ node: PaneNode) -> [UUID] {
    guard case .split(let id, _, _, let first, let second) = node else { return [] }
    return [id] + splitIDs(first) + splitIDs(second)
}

@MainActor
struct PaneTilingTests {
    let a = PaneID()
    let b = PaneID()
    let c = PaneID()
    let d = PaneID()

    @Test func insertingBesideAPanePutsTheNewNodeOnThatEdge() {
        let left = PaneNode.leaf(a).inserting(.leaf(b), at: .pane(a), edge: .left)
        let below = PaneNode.leaf(a).inserting(.leaf(b), at: .pane(a), edge: .bottom)

        guard case .split(_, .horizontal, 0.5, .leaf(b), .leaf(a)) = left,
              case .split(_, .vertical, 0.5, .leaf(a), .leaf(b)) = below
        else {
            Issue.record("unexpected shapes: \(left), \(below)")
            return
        }
    }

    @Test func insertingAtTheRootSpansTheWholeGrid() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .vertical, inserting: b)
        let result = tree.inserting(.leaf(c), at: .root, edge: .right)

        guard case .split(_, .horizontal, _, let first, .leaf(c)) = result else {
            Issue.record("unexpected shape: \(result)")
            return
        }
        #expect(first == tree)
    }

    @Test func insertingASubtreeKeepsItsShape() {
        let incoming = PaneNode.leaf(c).splitting(c, axis: .vertical, inserting: d)
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        let result = tree.inserting(incoming, at: .pane(b), edge: .top)

        #expect(result.leaves == [a, c, d, b])
        #expect(splitIDs(result).contains(splitIDs(incoming)[0]))
    }

    @Test func movingAPaneBesideAnother() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .horizontal, inserting: c)

        let result = tree.moving(c, to: .pane(a), edge: .left)

        #expect(result.leaves == [c, a, b])
        #expect(Set(result.leaves).count == 3)
    }

    @Test func movingAPaneOntoItselfOrOutOfTheTreeChangesNothing() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)

        #expect(tree.moving(a, to: .pane(a), edge: .left) == tree)
        #expect(tree.moving(c, to: .pane(a), edge: .left) == tree)
        #expect(tree.moving(a, to: .pane(c), edge: .left) == tree)
        #expect(PaneNode.leaf(a).moving(a, to: .root, edge: .left) == .leaf(a))
    }

    @Test func movingToTheRootEdge() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)

        let result = tree.moving(c, to: .root, edge: .bottom)

        guard case .split(_, .vertical, _, let top, .leaf(c)) = result else {
            Issue.record("unexpected shape: \(result)")
            return
        }
        #expect(top.leaves == [a, b])
    }

    @Test func swappingExchangesPositionsAndKeepsSplits() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)

        let result = tree.swapping(a, c)

        #expect(result.leaves == [c, b, a])
        #expect(splitIDs(result) == splitIDs(tree))
        #expect(tree.swapping(a, d) == tree)
        #expect(tree.swapping(a, a) == tree)
    }

    @Test func equalizingGivesARunOfSplitsEqualShares() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .horizontal, inserting: c)

        let even = tree.equalized()
        let layout = PaneLayout(node: even, size: CGSize(width: 302, height: 100))
        let widths = layout.panes.map(\.frame.width)

        #expect(widths.count == 3)
        #expect(widths.max()! - widths.min()! < 1)
    }

    @Test func equalizingOneSplitLeavesTheOthers() {
        var tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        tree = tree.splitting(b, axis: .vertical, inserting: c)
        let ids = splitIDs(tree)
        tree = tree.resizing(split: ids[0], to: 0.2).resizing(split: ids[1], to: 0.8)

        let result = tree.equalized(only: ids[1])

        #expect(ratios(result) == [0.2, 0.5])
    }

    @Test func dropTargetPicksTheNearestEdgeOfThePane() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        let layout = PaneLayout(node: tree, size: CGSize(width: 401, height: 200))

        #expect(layout.dropTarget(at: CGPoint(x: 60, y: 100), allowsSwap: false) == PaneDrop(anchor: .pane(a), edge: .left))
        #expect(layout.dropTarget(at: CGPoint(x: 190, y: 100), allowsSwap: false) == PaneDrop(anchor: .pane(a), edge: .right))
        #expect(layout.dropTarget(at: CGPoint(x: 300, y: 40), allowsSwap: false) == PaneDrop(anchor: .pane(b), edge: .top))
        #expect(layout.dropTarget(at: CGPoint(x: 300, y: 170), allowsSwap: false) == PaneDrop(anchor: .pane(b), edge: .bottom))
    }

    @Test func dropTargetSwapsInTheMiddleOnlyWhenAllowed() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        let layout = PaneLayout(node: tree, size: CGSize(width: 401, height: 200))
        let middle = CGPoint(x: 300, y: 100)

        #expect(layout.dropTarget(at: middle, allowsSwap: true) == PaneDrop(anchor: .pane(b), edge: nil))
        #expect(layout.dropTarget(at: middle, allowsSwap: false)?.edge != nil)
    }

    @Test func dropTargetNearTheOuterEdgeSpansTheGrid() {
        let tree = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: b)
        let layout = PaneLayout(node: tree, size: CGSize(width: 401, height: 200))

        #expect(layout.dropTarget(at: CGPoint(x: 5, y: 100), allowsSwap: true) == PaneDrop(anchor: .root, edge: .left))
        #expect(layout.dropTarget(at: CGPoint(x: 200, y: 195), allowsSwap: true) == PaneDrop(anchor: .root, edge: .bottom))
        #expect(layout.dropTarget(at: CGPoint(x: 500, y: 100), allowsSwap: true) == nil)
    }

    @Test func singlePaneHasNoRootBand() {
        let layout = PaneLayout(node: .leaf(a), size: CGSize(width: 400, height: 200))

        #expect(layout.dropTarget(at: CGPoint(x: 5, y: 100), allowsSwap: false) == PaneDrop(anchor: .pane(a), edge: .left))
    }

    @Test func previewCoversTheHalfThePaneWouldTake() {
        let layout = PaneLayout(node: .leaf(a), size: CGSize(width: 400, height: 200))

        #expect(layout.previewFrame(for: PaneDrop(anchor: .pane(a), edge: .right)) == CGRect(x: 200, y: 0, width: 200, height: 200))
        #expect(layout.previewFrame(for: PaneDrop(anchor: .root, edge: .top)) == CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(layout.previewFrame(for: PaneDrop(anchor: .pane(a), edge: nil)) == CGRect(x: 0, y: 0, width: 400, height: 200))
        #expect(layout.previewFrame(for: PaneDrop(anchor: .pane(b), edge: .left)) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct WorkspaceTilingTests {
    private func makeWorkspace(shells: Int = 1) -> Workspace {
        let workspace = Workspace(closeCoordinator: CloseCoordinator { _ in true })
        for _ in 1..<shells { workspace.newShell() }
        return workspace
    }

    @Test func droppingAShellTilesItIntoTheActiveGrid() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let first = workspace.tabs[0]
        let second = workspace.tabs[1]
        workspace.selectTab(first.id)

        workspace.drop(.tab(second.id), on: PaneDrop(anchor: .pane(first.focusedPane), edge: .right))

        #expect(workspace.tabs.count == 1)
        #expect(workspace.activeTabID == first.id)
        #expect(workspace.layout.leaves == [first.focusedPane, second.focusedPane])
        #expect(workspace.focusedPane == second.focusedPane)
        #expect(workspace.session(for: second.focusedPane)?.isOpen == true)
    }

    @Test func theActiveShellCannotBeDroppedIntoItself() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let active = workspace.tabs[1]

        #expect(!workspace.canDrop(.tab(active.id), on: PaneDrop(anchor: .root, edge: .left)))
        workspace.drop(.tab(active.id), on: PaneDrop(anchor: .root, edge: .left))
        #expect(workspace.tabs.count == 2)
    }

    @Test func movingAPaneWithinTheGrid() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let a = workspace.focusedPane
        workspace.split(.horizontal)
        let b = workspace.focusedPane
        workspace.split(.vertical)
        let c = workspace.focusedPane

        workspace.drop(.pane(c), on: PaneDrop(anchor: .pane(a), edge: .left))
        #expect(workspace.layout.leaves == [c, a, b])

        workspace.drop(.pane(a), on: PaneDrop(anchor: .pane(b), edge: nil))
        #expect(workspace.layout.leaves == [c, b, a])
        #expect(workspace.focusedPane == a)
    }

    @Test func aLonePaneCannotMoveWithinItsOwnGrid() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }

        #expect(!workspace.canDrop(.pane(workspace.focusedPane), on: PaneDrop(anchor: .root, edge: .left)))
    }

    @Test func movingAPaneInFromAnotherShell() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let source = workspace.tabs[0]
        let kept = source.focusedPane
        workspace.selectTab(source.id)
        workspace.split(.horizontal)
        let moved = workspace.focusedPane
        let target = workspace.tabs[1]
        workspace.selectTab(target.id)

        #expect(!workspace.canDrop(.pane(moved), on: PaneDrop(anchor: .pane(target.focusedPane), edge: nil)))
        workspace.drop(.pane(moved), on: PaneDrop(anchor: .pane(target.focusedPane), edge: .bottom))

        #expect(workspace.layout.leaves == [target.focusedPane, moved])
        #expect(workspace.tabs[0].layout == .leaf(kept))
        #expect(workspace.tabs[0].focusedPane == kept)
    }

    @Test func movingAShellsLastPaneAwayClosesThatShell() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let source = workspace.tabs[0]
        let target = workspace.tabs[1]

        workspace.drop(.pane(source.focusedPane), on: PaneDrop(anchor: .root, edge: .left))

        #expect(workspace.tabs.map(\.id) == [target.id])
        #expect(workspace.layout.leaves == [source.focusedPane, target.focusedPane])
    }

    @Test func breakingOutAPaneGivesItItsOwnShellAfterTheOriginal() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let origin = workspace.tabs[0]
        workspace.selectTab(origin.id)
        workspace.split(.horizontal)
        let pane = workspace.focusedPane

        workspace.breakOut(pane)

        #expect(workspace.tabs.count == 3)
        #expect(workspace.tabs[0].layout == .leaf(origin.focusedPane))
        #expect(workspace.tabs[1].layout == .leaf(pane))
        #expect(workspace.activeTabID == workspace.tabs[1].id)
        #expect(workspace.session(for: pane)?.isOpen == true)
        #expect(!workspace.canBreakOut(pane))
    }

    @Test func movedPanesStillCloseFromTheirNewShell() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let source = workspace.tabs[0]
        let target = workspace.tabs[1]
        workspace.drop(.tab(source.id), on: PaneDrop(anchor: .root, edge: .left))

        workspace.close(source.focusedPane)

        #expect(workspace.tabs.count == 1)
        #expect(workspace.layout == .leaf(target.focusedPane))
        #expect(workspace.session(for: source.focusedPane) == nil)
    }

    @Test func settingsCannotBeTiled() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        let pane = workspace.focusedPane
        workspace.openSettings()
        let settings = workspace.activeTabID

        #expect(!workspace.canDrop(.pane(pane), on: PaneDrop(anchor: .root, edge: .left)))
        workspace.selectTab(workspace.tabs[0].id)
        #expect(!workspace.canDrop(.tab(settings), on: PaneDrop(anchor: .root, edge: .left)))
    }

    @Test func draggingTheActiveShellBringsTheLastOneForwardToTakeIt() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)
        workspace.selectTab(ids[0])
        workspace.selectTab(ids[2])
        let drag = TileDrag()

        drag.begin(.tab(ids[2]), title: "", in: workspace)

        #expect(workspace.activeTabID == ids[0])
        #expect(workspace.canDrop(.tab(ids[2]), on: PaneDrop(anchor: .root, edge: .right)))
    }

    @Test func aCancelledDragPutsTheActiveShellBack() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)
        let drag = TileDrag()
        drag.begin(.tab(ids[1]), title: "", in: workspace)
        #expect(workspace.activeTabID == ids[0])

        drag.cancel(in: workspace)

        #expect(workspace.activeTabID == ids[1])
        #expect(!drag.isActive)
    }

    @Test func aHoverOutlineClearsWhenThePanesOfTheRowChange() {
        let drag = TileDrag()
        let first = PaneID()
        let second = PaneID()
        drag.hover([first], true)

        drag.hover([first, second], false)

        #expect(drag.hovered.isEmpty)
    }

    @Test func leavingAnotherRowKeepsTheHoverOutline() {
        let drag = TileDrag()
        let first = PaneID()
        drag.hover([first], true)

        drag.hover([PaneID()], false)

        #expect(drag.hovered == [first])
    }

    @Test func droppingTheActiveShellTilesItIntoTheLastOne() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let first = workspace.tabs[0]
        let second = workspace.tabs[1]
        let drag = TileDrag()
        drag.gridFrame = CGRect(x: 200, y: 0, width: 400, height: 300)
        drag.windowBounds = CGRect(x: 0, y: 0, width: 600, height: 300)
        drag.begin(.tab(second.id), title: "", in: workspace)

        drag.move(to: CGPoint(x: 560, y: 150), in: workspace)
        #expect(drag.drop == PaneDrop(anchor: .pane(first.focusedPane), edge: .right))
        #expect(drag.end(in: workspace))

        #expect(workspace.tabs.map(\.id) == [first.id])
        #expect(workspace.layout.leaves == [first.focusedPane, second.focusedPane])
    }

    @Test func lastActiveShellSkipsSettingsAndClosedShells() {
        let workspace = makeWorkspace(shells: 3)
        defer { workspace.terminateAll() }
        let ids = workspace.tabs.map(\.id)
        workspace.selectTab(ids[0])
        workspace.openSettings()
        workspace.selectTab(ids[1])
        workspace.selectTab(ids[2])

        #expect(workspace.lastActiveShell(before: ids[2]) == ids[1])
        workspace.closeTab(ids[1])
        #expect(workspace.lastActiveShell(before: ids[2]) == ids[0])
    }

    @Test func aSplitShellCanBeNamedAsAWhole() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        workspace.split(.horizontal)
        let id = workspace.activeTabID

        workspace.renameTab(id, to: "  servers ")
        #expect(workspace.tabs[0].title == "servers")
        #expect(workspace.shells(matching: "servers").map(\.id) == [id])

        workspace.renameTab(id, to: " ")
        #expect(workspace.tabs[0].title == nil)
    }

    @Test func aShellMovesToAnotherWindowStillRunning() {
        let source = makeWorkspace(shells: 2)
        let target = makeWorkspace()
        defer {
            source.terminateAll()
            target.terminateAll()
        }
        let moving = source.tabs[0]
        source.selectTab(moving.id)
        source.split(.vertical)
        source.renameTab(moving.id, to: "pair")
        let panes = source.tabs[0].layout.leaves

        #expect(source.canTearOff(.tab(moving.id)))
        guard let shell = source.release(.tab(moving.id)) else {
            Issue.record("release returned nothing")
            return
        }
        target.receive(shell)

        #expect(source.tabs.count == 1)
        #expect(panes.allSatisfy { source.session(for: $0) == nil })
        #expect(target.tabs.count == 2)
        #expect(target.layout.leaves == panes)
        #expect(target.tabs[1].title == "pair")
        #expect(panes.allSatisfy { target.session(for: $0)?.isOpen == true })

        target.close(panes[0])
        #expect(target.layout == .leaf(panes[1]))
    }

    @Test func aNewWindowStartsWithTheTornOffPane() {
        let source = makeWorkspace()
        defer { source.terminateAll() }
        let kept = source.focusedPane
        source.split(.horizontal)
        let pane = source.focusedPane

        #expect(source.canTearOff(.pane(pane)))
        guard let shell = source.release(.pane(pane)) else {
            Issue.record("release returned nothing")
            return
        }
        let window = Workspace(closeCoordinator: CloseCoordinator { _ in true }, transfer: shell)
        defer { window.terminateAll() }

        #expect(source.layout == .leaf(kept))
        #expect(window.tabs.count == 1)
        #expect(window.layout == .leaf(pane))
        #expect(window.session(for: pane)?.isOpen == true)
    }

    @Test func theOnlyShellCannotTearOffIntoANewWindow() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }

        #expect(!workspace.canTearOff(.tab(workspace.activeTabID)))
        #expect(!workspace.canTearOff(.pane(workspace.focusedPane)))
    }

    @Test func releasingTheLastShellEmptiesTheWindow() {
        let workspace = makeWorkspace()
        defer { workspace.terminateAll() }
        var emptied = false
        workspace.onEmpty = { emptied = true }

        let shell = workspace.release(.tab(workspace.activeTabID))

        #expect(shell?.sessions.count == 1)
        #expect(emptied)
        shell?.sessions.values.forEach { $0.terminate() }
    }

    @Test func hoverFollowsTheRowUnderThePointer() {
        let drag = TileDrag()
        let a: Set = [PaneID()]
        let b: Set = [PaneID(), PaneID()]

        drag.hover(a, true)
        drag.hover(b, true)
        drag.hover(a, false)
        #expect(drag.hovered == b)

        drag.hover(b, false)
        #expect(drag.hovered.isEmpty)
    }
}
