import SwiftUI
import TurmCore

private let pulseDuration: TimeInterval = 1.6

struct ProgramMark<Fallback: View>: View {
    let program: RunningProgram?
    let activity: CompanionActivity
    var size: CGFloat = 16
    @ViewBuilder let fallback: Fallback
    @State private var pulse: (start: Date, color: Color)?

    var body: some View {
        Group {
            if let program, activity.isBusy {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pulseDuration) / pulseDuration
                    glyph(program, tint: Chrome.text).opacity(0.65 + 0.35 * (0.5 + 0.5 * sin(phase * 2 * .pi)))
                }
            } else if let program, let pulse {
                TimelineView(.animation) { timeline in
                    let progress = min(max(timeline.date.timeIntervalSince(pulse.start) / pulseDuration, 0), 1)
                    let wave = (progress * 2).truncatingRemainder(dividingBy: 1)
                    let handoff = max(progress - 0.75, 0) / 0.25
                    ZStack {
                        fallback.opacity(handoff)
                        glyph(program, tint: pulse.color)
                            .opacity((1 - handoff) * (0.65 + 0.35 * (0.5 + 0.5 * cos(wave * 2 * .pi))))
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: program == nil ? nil : size, height: program == nil ? nil : size)
        .onChange(of: activity) { old, new in
            guard old.isBusy, program != nil, let color = Self.outcomeColor(new) else {
                if new.isBusy { pulse = nil }
                return
            }
            let start = Date()
            pulse = (start, color)
            Task {
                try? await Task.sleep(for: .seconds(pulseDuration))
                if pulse?.start == start { pulse = nil }
            }
        }
    }

    private static func outcomeColor(_ activity: CompanionActivity) -> Color? {
        switch activity {
        case .succeeded: Chrome.success
        case .failed: Chrome.failure
        default: nil
        }
    }

    private func glyph(_ program: RunningProgram, tint: Color) -> some View {
        ProgramGlyph(program, size: size)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

extension CompanionActivity {
    var isBusy: Bool {
        switch self {
        case .working, .progress: true
        default: false
        }
    }

    static func outcome(running: Bool, exitCode: Int32?) -> CompanionActivity {
        if running { return .working }
        guard let exitCode else { return .inactive }
        return exitCode == 0 ? .succeeded : .failed
    }
}

struct TabStatusMark: View {
    let tab: any TerminalTab
    var dotSize: CGFloat = 8
    var markSize: CGFloat = 16

    var body: some View {
        ProgramMark(program: tab.program, activity: tab.programActivity, size: markSize) {
            StatusDot(color: tab.indicator.color, size: dotSize)
        }
    }
}
