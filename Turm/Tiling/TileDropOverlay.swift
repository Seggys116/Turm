import SwiftUI

struct TileDropOverlay: View {
    let workspace: Workspace
    let drag: TileDrag

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = drag.previewFrame(in: workspace) {
                zone(frame.insetBy(dx: 3, dy: 3), label: drag.drop?.edge == nil ? "Swap" : nil)
            } else if drag.breaksOut {
                zone(drag.sidebarFrame.insetBy(dx: 3, dy: 3), label: "New Shell")
            }
            if drag.isActive, !drag.tearsOff {
                Text(drag.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .frame(maxWidth: 220)
                    .fixedSize()
                    .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: ShellSidebar.corner))
                    .overlay(RoundedRectangle(cornerRadius: ShellSidebar.corner).stroke(Theme.chipStroke.color, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .offset(x: drag.location.x + 14, y: drag.location.y + 10)
                    .transaction { $0.animation = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: drag.drop)
        .animation(.easeOut(duration: 0.12), value: drag.breaksOut)
        .allowsHitTesting(false)
    }

    private func zone(_ frame: CGRect, label: String?) -> some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(4)), isUniform: false)
        return shape
            .fill(Color.accentColor.opacity(0.22))
            .overlay(shape.stroke(Color.accentColor.opacity(0.9), lineWidth: 2))
            .overlay {
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text.color)
                }
            }
            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
            .position(x: frame.midX, y: frame.midY)
            .transition(.opacity)
    }
}
