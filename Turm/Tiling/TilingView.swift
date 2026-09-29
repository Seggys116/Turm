import SwiftUI

struct TilingView: View {
    let workspace: Workspace
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let pane):
            if let session = workspace.session(for: pane) {
                TerminalPaneView(session: session, isFocused: workspace.focusedPane == pane)
            }
        case .split(let id, let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, onRatioChange: { workspace.resize(split: id, to: $0) }) {
                TilingView(workspace: workspace, node: first)
            } second: {
                TilingView(workspace: workspace, node: second)
            }
        }
    }
}

private struct SplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let onRatioChange: (Double) -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    private let dividerThickness: CGFloat = 1
    private let dividerHitArea: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(length - dividerThickness, 1)
            let firstLength = available * ratio

            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        first.frame(width: firstLength)
                        divider
                        second.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        first.frame(height: firstLength)
                        divider
                        second.frame(maxHeight: .infinity)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                dragHandle(available: available, firstLength: firstLength)
            }
            .coordinateSpace(name: SplitSpace.name)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(
                width: axis == .horizontal ? dividerThickness : nil,
                height: axis == .vertical ? dividerThickness : nil
            )
    }

    private func dragHandle(available: CGFloat, firstLength: CGFloat) -> some View {
        Color.clear
            .frame(
                width: axis == .horizontal ? dividerHitArea : nil,
                height: axis == .vertical ? dividerHitArea : nil
            )
            .contentShape(Rectangle())
            .offset(
                x: axis == .horizontal ? firstLength - (dividerHitArea - dividerThickness) / 2 : 0,
                y: axis == .vertical ? firstLength - (dividerHitArea - dividerThickness) / 2 : 0
            )
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(SplitSpace.name))
                    .onChanged { drag in
                        let position = axis == .horizontal ? drag.location.x : drag.location.y
                        onRatioChange(Double(position / available))
                    }
            )
    }
}

private enum SplitSpace {
    static let name = "turm.split"
}
