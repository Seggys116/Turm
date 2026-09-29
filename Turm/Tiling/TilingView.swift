import SwiftUI

struct TilingView: View {
    let workspace: Workspace
    let node: PaneNode
    let focusedPane: PaneID
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = PaneLayout(node: node, size: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.id) { pane in
                    if let session = workspace.session(for: pane.id) {
                        TerminalPaneView(session: session, isFocused: isActive && focusedPane == pane.id)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .position(x: pane.frame.midX, y: pane.frame.midY)
                    }
                }
                ForEach(layout.dividers, id: \.split) { divider in
                    SplitDivider(divider: divider) { workspace.resize(split: divider.split, to: $0) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: SplitSpace.name)
        }
    }
}

private struct SplitDivider: View {
    let divider: PaneLayout.Divider
    let onRatioChange: (Double) -> Void

    private let hitArea: CGFloat = 9

    var body: some View {
        let frame = divider.frame
        let horizontal = divider.axis == .horizontal
        Rectangle()
            .fill(Theme.divider.color)
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
            .position(x: frame.midX, y: frame.midY)
    }
}

private enum SplitSpace {
    static let name = "turm.split"
}
