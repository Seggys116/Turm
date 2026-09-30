import AppKit
import SwiftUI

enum ScrollbarMetrics {
    static let thickness: CGFloat = 4
    static let activeThickness: CGFloat = 7
    static let inset: CGFloat = 2
    static let hitWidth: CGFloat = 12
    static let minimumKnob: CGFloat = 24
    static let idleDelay: Duration = .milliseconds(1200)

    static func knobLength(track: CGFloat, viewport: CGFloat, content: CGFloat) -> CGFloat {
        guard content > 0 else { return track }
        return min(track, max(track * viewport / content, minimumKnob))
    }

    static func knobOffset(track: CGFloat, knob: CGFloat, offset: CGFloat, range: CGFloat) -> CGFloat {
        guard range > 0 else { return 0 }
        return (track - knob) * min(max(offset / range, 0), 1)
    }

    static func contentOffset(forKnobOffset knobOffset: CGFloat, track: CGFloat, knob: CGFloat, range: CGFloat) -> CGFloat {
        let travel = track - knob
        guard travel > 0 else { return 0 }
        return min(max(knobOffset / travel, 0), 1) * range
    }
}

extension View {
    func squareScrollbar(position: Binding<ScrollPosition>? = nil) -> some View {
        modifier(SquareScrollbar(external: position))
    }
}

// state lives outside the modifier so geometry updates re-render only the knob, never the scroll view
@Observable
private final class ScrollbarState {
    var metrics = ScrollMetrics()
    var visible = false
    var hovering = false
    var dragOrigin: CGFloat?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    var range: CGFloat { max(metrics.content - metrics.viewport, 0) }
    var overflows: Bool { metrics.viewport > 0 && range > 1 }
    var active: Bool { hovering || dragOrigin != nil }

    func reveal() {
        if !visible { visible = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ScrollbarMetrics.idleDelay)
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }
}

private struct SquareScrollbar: ViewModifier {
    let external: Binding<ScrollPosition>?
    @State private var own = ScrollPosition()
    @State private var state = ScrollbarState()

    func body(content: Content) -> some View {
        let position = external ?? $own
        let state = state
        content
            .scrollIndicators(.never)
            .scrollPosition(position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    viewport: geometry.containerSize.height,
                    content: geometry.contentSize.height
                )
            } action: { old, new in
                state.metrics = new
                if old.offset != new.offset { state.reveal() }
            }
            .overlay(alignment: .trailing) {
                ScrollbarKnob(state: state, position: position)
            }
    }
}

private struct ScrollbarKnob: View {
    let state: ScrollbarState
    let position: Binding<ScrollPosition>

    private var alwaysShown: Bool { NSScroller.preferredScrollerStyle == .legacy }

    var body: some View {
        if state.overflows {
            GeometryReader { proxy in
                let metrics = state.metrics
                let track = proxy.size.height - ScrollbarMetrics.inset * 2
                let knob = ScrollbarMetrics.knobLength(track: track, viewport: metrics.viewport, content: metrics.content)
                let top = ScrollbarMetrics.knobOffset(track: track, knob: knob, offset: metrics.offset, range: state.range)
                Rectangle()
                    .fill((state.active ? Theme.scrollKnobActive : Theme.scrollKnob).color)
                    .frame(width: state.active ? ScrollbarMetrics.activeThickness : ScrollbarMetrics.thickness, height: knob)
                    .offset(y: ScrollbarMetrics.inset + top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, ScrollbarMetrics.inset)
                    .contentShape(Rectangle())
                    .gesture(drag(track: track, knob: knob, top: top))
            }
            .frame(width: ScrollbarMetrics.hitWidth)
            .opacity(state.visible || state.active || alwaysShown ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: state.active)
            .animation(.easeOut(duration: 0.25), value: state.visible)
            .onHover { inside in
                state.hovering = inside
                if !inside { state.reveal() }
            }
        }
    }

    private func drag(track: CGFloat, knob: CGFloat, top: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if state.dragOrigin == nil {
                    let pressed = value.startLocation.y - ScrollbarMetrics.inset
                    state.dragOrigin = (top...(top + knob)).contains(pressed) ? top : pressed - knob / 2
                }
                guard let origin = state.dragOrigin else { return }
                let y = ScrollbarMetrics.contentOffset(
                    forKnobOffset: origin + value.translation.height, track: track, knob: knob, range: state.range
                )
                position.wrappedValue.scrollTo(y: y)
            }
            .onEnded { _ in
                state.dragOrigin = nil
                state.reveal()
            }
    }
}

final class SquareScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let slot = rect(for: .knob).insetBy(dx: 0, dy: ScrollbarMetrics.inset)
        guard slot.height > 0 else { return }
        let width = min(ScrollbarMetrics.thickness, slot.width)
        let knob = NSRect(x: bounds.maxX - width - ScrollbarMetrics.inset, y: slot.minY, width: width, height: slot.height)
        Theme.scrollKnob.resolved(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua).setFill()
        knob.fill()
    }
}
