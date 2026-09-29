import AppKit
import SwiftUI

struct MouseReporter: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.session = session
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) {
        view.session = session
    }
}

final class MouseView: NSView {
    var session: TerminalSession?
    private var held: MouseButton?
    private var horizontal = WheelAccumulator()
    private var vertical = WheelAccumulator()

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let session, session.mouseTracking != .off else { return nil }
        guard !NSEvent.modifierFlags.contains(.shift) || session.mouseShiftCaptured else { return nil }
        let local = convert(point, from: superview)
        guard let frame = session.runningOutputFrame, frame.contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        press(.left, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        press(.right, event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        press(.middle, event)
    }

    override func mouseUp(with event: NSEvent) {
        release(.left, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        release(.right, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        release(.middle, event)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        drag(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        drag(event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let session, session.mouseTracking == .any, held == nil, isReportable(event) else { return }
        send(.motion, button: nil, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, session.mouseTracking != .off, isReportable(event) else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began || event.phase == .mayBegin {
            horizontal.reset()
            vertical.reset()
        }
        let precise = event.hasPreciseScrollingDeltas
        let rowUnit = precise ? TerminalMetrics.lineHeight : 1
        let colUnit = precise ? TerminalMetrics.cellWidth : 1
        let rows = vertical.steps(delta: event.scrollingDeltaY, unit: rowUnit)
        let cols = horizontal.steps(delta: event.scrollingDeltaX, unit: colUnit)
        for _ in 0..<abs(rows) {
            send(.press, button: rows > 0 ? .wheelUp : .wheelDown, event)
        }
        for _ in 0..<abs(cols) {
            send(.press, button: cols > 0 ? .wheelLeft : .wheelRight, event)
        }
    }

    private func press(_ button: MouseButton, _ event: NSEvent) {
        session?.focus()
        held = button
        send(.press, button: button, event)
    }

    private func release(_ button: MouseButton, _ event: NSEvent) {
        if held == button { held = nil }
        send(.release, button: button, event)
    }

    private func drag(_ event: NSEvent) {
        guard let held else { return }
        send(.motion, button: held, event)
    }

    private func isReportable(_ event: NSEvent) -> Bool {
        guard let session, let frame = session.runningOutputFrame else { return false }
        let shifted = event.modifierFlags.contains(.shift)
        guard !shifted || session.mouseShiftCaptured else { return false }
        return frame.contains(convert(event.locationInWindow, from: nil))
    }

    private func send(_ action: MouseAction, button: MouseButton?, _ event: NSEvent) {
        guard let session, let frame = session.runningOutputFrame else { return }
        let point = convert(event.locationInWindow, from: nil)
        var modifiers: MouseModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let mouse = MouseEvent(
            action: action,
            button: button,
            modifiers: modifiers,
            x: point.x - frame.minX,
            y: point.y - frame.minY
        )
        session.reportMouse(mouse, scale: window?.backingScaleFactor ?? 1)
    }
}
