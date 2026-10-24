import SwiftUI

struct WindowCloseGuard: NSViewRepresentable {
    let host: WindowHost

    func makeNSView(context: Context) -> WindowCloseView {
        WindowCloseView(host: host)
    }

    func updateNSView(_ view: WindowCloseView, context: Context) {
        view.host = host
        view.bindCurrentWorkspace()
    }

    static func dismantleNSView(_ view: WindowCloseView, coordinator: ()) {
        view.detach()
    }
}

final class WindowCloseView: NSView, NSWindowDelegate {
    var host: WindowHost
    private weak var observedWindow: NSWindow?
    private weak var originalDelegate: (any NSWindowDelegate)?
    private weak var boundWorkspace: Workspace?

    init(host: WindowHost) {
        self.host = host
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
        bindCurrentWorkspace()
    }

    func bindCurrentWorkspace() {
        guard let window else { return }
        let workspace = SpaceLibrary.shared.workspace(for: host)
        guard boundWorkspace !== workspace else { return }
        ContextMenuService.shared.register(workspace, in: window)
        boundWorkspace = workspace
    }

    func detach() {
        if let observedWindow {
            ContextMenuService.shared.unregister(observedWindow)
            if observedWindow.delegate === self { observedWindow.delegate = originalDelegate }
        }
        observedWindow = nil
        originalDelegate = nil
        boundWorkspace = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard originalDelegate?.windowShouldClose?(sender) ?? true else { return false }
        if Self.otherMainWindows(besides: sender) > 0 { return true }
        let count = SpaceLibrary.shared.shellsRequiringConfirmation()
        if count == 0 { return true }
        return CloseCoordinator.shared.confirm(.application(shellCount: count))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ContextMenuService.shared.windowBecameKey(window) }
        originalDelegate?.windowDidBecomeKey?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            ContextMenuService.shared.unregister(window)
            let others = Self.otherMainWindows(besides: window)
            SpaceLibrary.shared.noteWindowClosing(host, frame: window.frame, isLast: others == 0)
        }
        if WorkspacePersistence.savesOnClose(otherVisibleMainWindows: Self.otherMainWindows(besides: window)) {
            WorkspacePersistence.prepareToQuit()
            SpaceLibrary.shared.saveAll()
            CloseCoordinator.shared.terminateAll()
        } else {
            SpaceLibrary.shared.saveAll()
        }
        originalDelegate?.windowWillClose?(notification)
    }

    private static func otherMainWindows(besides window: NSWindow?) -> Int {
        NSApp.windows.filter { candidate in
            candidate !== window && candidate.isVisible && candidate.canBecomeKey && candidate.level == .normal
        }.count
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
