import SwiftTerm
import SwiftUI

struct ProgressStrip: View {
    let report: Terminal.ProgressReport

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.subtleDivider.color)
                if report.state == .indeterminate {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Rectangle()
                            .fill(color)
                            .frame(width: proxy.size.width * 0.25)
                            .offset(x: (proxy.size.width * 1.25) * phase - proxy.size.width * 0.25)
                    }
                } else {
                    Rectangle()
                        .fill(color)
                        .frame(width: proxy.size.width * Double(report.progress ?? 0) / 100)
                }
            }
            .clipped()
        }
        .frame(height: 2)
    }

    private var color: SwiftUI.Color {
        switch report.state {
        case .error: Theme.failure.color
        case .pause: Theme.secondaryText.color
        default: Theme.added.color
        }
    }
}
