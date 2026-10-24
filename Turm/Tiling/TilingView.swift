import SwiftUI

struct TilingView: View {
    let workspace: Workspace
    let node: PaneNode
    let focusedPane: PaneID
    let isActive: Bool
    let tileDrag: TileDrag

    var body: some View {
        GeometryReader { geometry in
            let layout = PaneLayout(node: node, size: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.id) { pane in
                    let gapped = layout.panes.count > 1
                    let visual = paneSeam(pane.frame, in: layout.bounds, gapped: gapped)
                    Group {
                        if let viewer = workspace.viewers[pane.id] {
                            ViewerPaneView(workspace: workspace, pane: pane.id, viewer: viewer)
                        } else if let session = workspace.session(for: pane.id) {
                            TerminalPaneView(session: session, isFocused: isActive && focusedPane == pane.id)
                        }
                    }
                    .paneCard(
                        isSplit: gapped,
                        isFocused: isActive && focusedPane == pane.id,
                        corners: PaneCorners.resolve(visual, in: layout.bounds)
                    )
                    .opacity(isActive && tileDrag.item == .pane(pane.id) ? 0.45 : 1)
                    .overlay {
                        if isActive, tileDrag.hovered.contains(pane.id) {
                            let shape = PaneCorners.resolve(visual, in: layout.bounds).shape
                            shape
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 4)
                                .mask(shape)
                                .allowsHitTesting(false)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: tileDrag.hovered.contains(pane.id))
                    .frame(width: visual.width, height: visual.height)
                    .position(x: visual.midX, y: visual.midY)
                }
                ForEach(layout.dividers, id: \.split) { divider in
                    SplitDivider(divider: divider) { workspace.resize(split: divider.split, to: $0) } onReset: {
                        withAnimation(.easeOut(duration: 0.15)) { workspace.equalizePanes(only: divider.split) }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(layout.panes.count > 1 ? Theme.windowBackground.color : Color.clear)
            .coordinateSpace(name: SplitSpace.name)
            .background(
                PaneDragMonitor(
                    isEnabled: isActive && layout.panes.count > 1,
                    begin: { point in beginDrag(at: point, in: layout) },
                    move: { point in tileDrag.move(to: windowPoint(point), in: workspace) },
                    end: { withAnimation(.easeOut(duration: 0.18)) { _ = tileDrag.end(in: workspace) } },
                    click: { point in
                        if let pane = layout.panes.first(where: { $0.frame.contains(point) }) { workspace.focus(pane.id) }
                    },
                    cancel: { tileDrag.cancel(in: workspace) }
                )
            )
        }
    }

    /// Pulls a pane back only where it meets another pane, so the window inset is not applied again.
    private func paneSeam(_ frame: CGRect, in bounds: CGRect, gapped: Bool) -> CGRect {
        guard gapped else { return frame }
        let gap = ChromeMetrics.paneGap / 2
        var visual = frame
        if visual.minX > bounds.minX + 0.5 {
            visual.origin.x += gap
            visual.size.width -= gap
        }
        if visual.maxX < bounds.maxX - 0.5 {
            visual.size.width -= gap
        }
        if visual.minY > bounds.minY + 0.5 {
            visual.origin.y += gap
            visual.size.height -= gap
        }
        if visual.maxY < bounds.maxY - 0.5 {
            visual.size.height -= gap
        }
        return visual
    }

    private func windowPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + tileDrag.gridFrame.minX, y: point.y + tileDrag.gridFrame.minY)
    }

    private func beginDrag(at point: CGPoint, in layout: PaneLayout) -> Bool {
        guard !tileDrag.isActive, let pane = layout.panes.first(where: { $0.frame.contains(point) }) else { return false }
        let title = workspace.session(for: pane.id).map { $0.customTitle ?? $0.location } ?? workspace.viewers[pane.id]?.title
        guard let title else { return false }
        workspace.focus(pane.id)
        tileDrag.begin(.pane(pane.id), title: title, in: workspace)
        return true
    }
}

private struct SplitDivider: View {
    let divider: PaneLayout.Divider
    let onRatioChange: (Double) -> Void
    let onReset: () -> Void

    private let hitArea: CGFloat = 9

    var body: some View {
        let frame = divider.frame
        let horizontal = divider.axis == .horizontal
        Rectangle()
            .fill(Color.clear)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
        Color.clear
            .frame(width: horizontal ? hitArea : frame.width, height: horizontal ? frame.height : hitArea)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(SplitSpace.name))
                    .onChanged { drag in onRatioChange(divider.ratio(at: drag.location)) }
            )
            .onTapGesture(count: 2, perform: onReset)
            .help("Drag to resize, double-click to even out")
            .position(x: frame.midX, y: frame.midY)
    }
}

private enum SplitSpace {
    static let name = "turm.split"
}
