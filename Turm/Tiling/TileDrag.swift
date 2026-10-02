import CoreGraphics
import Foundation
import Observation

@Observable
final class TileDrag {
    static let space = "turm.window"

    private(set) var item: TileItem?
    private(set) var title = ""
    private(set) var location: CGPoint = .zero
    private(set) var drop: PaneDrop?
    private(set) var breaksOut = false
    private(set) var tearsOff = false
    private var home: CGRect?
    private var restoring: UUID?
    private(set) var hovered: Set<PaneID> = []
    var gridFrame: CGRect = .zero
    var sidebarFrame: CGRect = .zero
    var windowBounds: CGRect = .zero
    var tearOff: (TileItem) -> Bool = { _ in false }

    var isActive: Bool { item != nil }

    func hover(_ panes: Set<PaneID>, _ inside: Bool) {
        if inside {
            hovered = panes
        } else if !hovered.isDisjoint(with: panes) {
            hovered = []
        }
    }

    func begin(_ item: TileItem, title: String, home: CGRect? = nil, in workspace: Workspace) {
        self.item = item
        self.title = title
        self.home = home
        if case .tab(let id) = item, id == workspace.activeTabID, let previous = workspace.lastActiveShell(before: id) {
            restoring = id
            workspace.selectTab(previous)
        }
    }

    func move(to point: CGPoint, in workspace: Workspace) {
        guard let item else { return }
        location = point
        drop = nil
        breaksOut = false
        tearsOff = false
        if !windowBounds.contains(point) {
            tearsOff = true
        } else if gridFrame.contains(point) {
            let local = CGPoint(x: point.x - gridFrame.minX, y: point.y - gridFrame.minY)
            let layout = PaneLayout(node: workspace.layout, size: gridFrame.size)
            let candidate = layout.dropTarget(at: local, allowsSwap: allowsSwap(item, in: workspace))
            drop = candidate.flatMap { workspace.canDrop(item, on: $0) ? $0 : nil }
        } else if sidebarFrame.contains(point), !(home?.contains(point) ?? false), case .pane(let pane) = item {
            breaksOut = workspace.canBreakOut(pane)
        }
    }

    @discardableResult
    func end(in workspace: Workspace) -> Bool {
        defer { cancel(in: workspace) }
        guard let item else { return false }
        if let drop {
            restoring = nil
            workspace.drop(item, on: drop)
            return true
        }
        if breaksOut, case .pane(let pane) = item {
            workspace.breakOut(pane)
            return true
        }
        if tearsOff, tearOff(item) {
            restoring = nil
            return true
        }
        return false
    }

    func cancel(in workspace: Workspace) {
        if let restoring, workspace.tabs.contains(where: { $0.id == restoring }) { workspace.selectTab(restoring) }
        cancel()
    }

    private func cancel() {
        item = nil
        title = ""
        home = nil
        restoring = nil
        tearsOff = false
        drop = nil
        breaksOut = false
    }

    func previewFrame(in workspace: Workspace) -> CGRect? {
        guard let drop else { return nil }
        let layout = PaneLayout(node: workspace.layout, size: gridFrame.size)
        return layout.previewFrame(for: drop)?.offsetBy(dx: gridFrame.minX, dy: gridFrame.minY)
    }

    private func allowsSwap(_ item: TileItem, in workspace: Workspace) -> Bool {
        guard case .pane(let pane) = item else { return false }
        return workspace.layout.contains(pane)
    }
}
