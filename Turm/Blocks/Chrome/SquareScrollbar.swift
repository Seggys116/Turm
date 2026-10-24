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

enum ScrollbarAxis {
    case vertical
    case horizontal
}

extension View {
    func squareScrollbar(
        axis: ScrollbarAxis = .vertical, overlays: Bool = false, position: Binding<ScrollPosition>? = nil, onDrag: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(SquareScrollbar(axis: axis, overlays: overlays, external: position, onDrag: onDrag))
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
    var axis: ScrollbarAxis = .vertical
    var overlays = false
    let external: Binding<ScrollPosition>?
    let onDrag: ((Bool) -> Void)?
    @State private var own = ScrollPosition()
    @State private var state = ScrollbarState()

    func body(content: Content) -> some View {
        let position = external ?? $own
        let state = state
        let vertical = axis == .vertical
        content
            .scrollIndicators(.never)
            .scrollPosition(position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: vertical ? geometry.contentOffset.y : geometry.contentOffset.x,
                    viewport: vertical ? geometry.containerSize.height : geometry.containerSize.width,
                    content: vertical ? geometry.contentSize.height : geometry.contentSize.width
                )
            } action: { old, new in
                state.metrics = new
                if abs(old.offset - new.offset) > 1 { state.reveal() }
            }
            .background(ScrollIndicatorSuppressor())
            .padding(.trailing, vertical && state.overflows && !overlays ? ScrollbarMetrics.hitWidth : 0)
            .overlay(alignment: vertical ? .trailing : .bottom) {
                ScrollbarKnob(axis: axis, state: state, position: position, onDrag: onDrag)
            }
    }
}

private struct ScrollbarKnob: View {
    var axis: ScrollbarAxis = .vertical
    let state: ScrollbarState
    let position: Binding<ScrollPosition>
    let onDrag: ((Bool) -> Void)?

    var body: some View {
        if state.overflows {
            GeometryReader { proxy in
                let metrics = state.metrics
                let vertical = axis == .vertical
                let span = vertical ? proxy.size.height : proxy.size.width
                let track = span - ScrollbarMetrics.inset * 2
                let knob = ScrollbarMetrics.knobLength(track: track, viewport: metrics.viewport, content: metrics.content)
                let origin = ScrollbarMetrics.knobOffset(track: track, knob: knob, offset: metrics.offset, range: state.range)
                let thickness = state.active ? ScrollbarMetrics.activeThickness : ScrollbarMetrics.thickness
                Rectangle()
                    .fill((state.active ? Theme.scrollKnobActive : Theme.scrollKnob).color)
                    .frame(width: vertical ? thickness : knob, height: vertical ? knob : thickness)
                    .offset(x: vertical ? 0 : ScrollbarMetrics.inset + origin, y: vertical ? ScrollbarMetrics.inset + origin : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .topTrailing : .bottomLeading)
                    .padding(vertical ? .trailing : .bottom, ScrollbarMetrics.inset)
                    .contentShape(Rectangle())
                    .gesture(drag(track: track, knob: knob, origin: origin))
            }
            .frame(width: axis == .vertical ? ScrollbarMetrics.hitWidth : nil, height: axis == .horizontal ? ScrollbarMetrics.hitWidth : nil)
            .opacity(state.visible || state.dragOrigin != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: state.active)
            .animation(.easeOut(duration: 0.25), value: state.visible)
            .onHover { state.hovering = $0 }
        }
    }

    private func drag(track: CGFloat, knob: CGFloat, origin: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let vertical = axis == .vertical
                if state.dragOrigin == nil {
                    onDrag?(true)
                    let pressed = (vertical ? value.startLocation.y : value.startLocation.x) - ScrollbarMetrics.inset
                    state.dragOrigin = (origin...(origin + knob)).contains(pressed) ? origin : pressed - knob / 2
                }
                guard let start = state.dragOrigin else { return }
                let travel = ScrollbarMetrics.contentOffset(
                    forKnobOffset: start + (vertical ? value.translation.height : value.translation.width),
                    track: track, knob: knob, range: state.range
                )
                if vertical {
                    position.wrappedValue.scrollTo(y: travel)
                } else {
                    position.wrappedValue.scrollTo(x: travel)
                }
            }
            .onEnded { _ in
                state.dragOrigin = nil
                onDrag?(false)
                state.reveal()
            }
    }
}

private struct ScrollIndicatorSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scroll = nsView.enclosingScrollView else { return }
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = false
            scroll.autohidesScrollers = true
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
