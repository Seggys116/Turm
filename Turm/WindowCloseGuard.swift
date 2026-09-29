import SwiftUI

struct WindowCloseGuard: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> WindowCloseView {
        WindowCloseView(workspace: workspace)
    }

    func updateNSView(_ view: WindowCloseView, context: Context) {}

    static func dismantleNSView(_ view: WindowCloseView, coordinator: ()) {
        view.detach()
    }
}

final class WindowCloseView: NSView, NSWindowDelegate {
    private let workspace: Workspace
    private weak var observedWindow: NSWindow?
    private weak var originalDelegate: (any NSWindowDelegate)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowCloseView is created in code only")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        detach()
        guard let window else { return }
        observedWindow = window
        originalDelegate = window.delegate
        window.delegate = self
        ContextMenuService.shared.register(workspace, in: window)
    }

    func detach() {
        if let observedWindow {
            ContextMenuService.shared.unregister(observedWindow)
            if observedWindow.delegate === self { observedWindow.delegate = originalDelegate }
        }
        observedWindow = nil
        originalDelegate = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard originalDelegate?.windowShouldClose?(sender) ?? true else { return false }
        return workspace.shouldCloseWindow()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ContextMenuService.shared.windowBecameKey(window) }
        originalDelegate?.windowDidBecomeKey?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ContextMenuService.shared.unregister(window) }
        workspace.terminateAll()
        originalDelegate?.windowWillClose?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}
