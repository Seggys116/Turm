import AppKit
import SwiftUI

extension View {
    func onOutsideFieldClick(isActive: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(OutsideFieldClickModifier(isActive: isActive, action: action))
    }
}

private struct OutsideFieldClickModifier: ViewModifier {
    let isActive: Bool
    let action: () -> Void
    @State private var monitor = ClickMonitor()

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active { monitor.start(action) } else { monitor.stop() }
            }
            .onDisappear { monitor.stop() }
    }
}

@MainActor
private final class ClickMonitor {
    private var token: Any?

    func start(_ action: @escaping () -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            nonisolated(unsafe) let captured = event
            MainActor.assumeIsolated {
                if !Self.isInsideFieldEditor(captured) {
                    DispatchQueue.main.async(execute: action)
                }
            }
            return event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private static func isInsideFieldEditor(_ event: NSEvent) -> Bool {
        guard let window = event.window, let hit = window.contentView?.hitTest(event.locationInWindow),
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor
        else { return false }
        if hit === editor || hit.isDescendant(of: editor) { return true }
        guard let field = editor.delegate as? NSView else { return false }
        return hit === field || hit.isDescendant(of: field)
    }
}
