import AppKit
import SwiftUI

struct PaneDragMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let begin: (CGPoint) -> Bool
    let move: (CGPoint) -> Void
    let end: () -> Void
    let click: (CGPoint) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        update(view)
    }

    private func update(_ view: MonitorView) {
        view.isEnabled = isEnabled
        view.onBegin = begin
        view.onMove = move
        view.onEnd = end
        view.onClick = click
        view.onCancel = cancel
    }

    final class MonitorView: NSView {
        private static let threshold: CGFloat = 4
        private static let escape: UInt16 = 53

        private enum Phase {
            case idle
            case pressed(CGPoint)
            case dragging
        }

        var isEnabled = false
        var onBegin: (CGPoint) -> Bool = { _ in false }
        var onMove: (CGPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onClick: (CGPoint) -> Void = { _ in }
        var onCancel: () -> Void = {}
        private var phase = Phase.idle
        private var monitor: Any?
        private var pendingDown: NSEvent?
        private var replaying: [Int] = []

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            pendingDown = nil
            replaying = []
            finish(cancelled: true)
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            if event.type != .keyDown, let index = replaying.firstIndex(of: event.eventNumber) {
                replaying.remove(at: index)
                return false
            }
            let point = convert(event.locationInWindow, from: nil)
            switch (event.type, phase) {
            case (.leftMouseDown, .idle):
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard isEnabled, modifiers == .command, bounds.contains(point) else { return false }
                phase = .pressed(point)
                pendingDown = event
                return true
            case (.leftMouseDragged, .pressed(let start)):
                guard hypot(point.x - start.x, point.y - start.y) >= Self.threshold else { return true }
                guard onBegin(start) else {
                    phase = .idle
                    pendingDown = nil
                    return true
                }
                pendingDown = nil
                phase = .dragging
                NSCursor.closedHand.push()
                onMove(point)
                return true
            case (.leftMouseDragged, .dragging):
                onMove(point)
                return true
            case (.leftMouseUp, .pressed(let start)):
                phase = .idle
                onClick(start)
                if let down = pendingDown {
                    pendingDown = nil
                    replaying = [down.eventNumber, event.eventNumber]
                    NSApp.postEvent(down, atStart: false)
                    NSApp.postEvent(event, atStart: false)
                }
                return true
            case (.leftMouseUp, .dragging):
                finish(cancelled: false)
                return true
            case (.keyDown, .dragging) where event.keyCode == Self.escape:
                finish(cancelled: true)
                return true
            default:
                return false
            }
        }

        private func finish(cancelled: Bool) {
            pendingDown = nil
            guard case .dragging = phase else {
                phase = .idle
                return
            }
            phase = .idle
            NSCursor.pop()
            if cancelled { onCancel() } else { onEnd() }
        }
    }
}
