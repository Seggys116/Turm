import SwiftUI

struct GitBranchIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 12
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            let radius = 1.6 * scale
            let stroke = StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round)

            var trunk = Path()
            trunk.move(to: point(3, 4.1))
            trunk.addLine(to: point(3, 7.9))
            var branch = Path()
            branch.move(to: point(9, 5.1))
            branch.addCurve(to: point(3, 7.6), control1: point(9, 7.2), control2: point(3.4, 6))
            context.stroke(trunk, with: .foreground, style: stroke)
            context.stroke(branch, with: .foreground, style: stroke)

            for center in [point(3, 2.5), point(3, 9.5), point(9, 3.5)] {
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .foreground, style: stroke)
            }
        }
        .frame(width: 12, height: 12)
    }
}
