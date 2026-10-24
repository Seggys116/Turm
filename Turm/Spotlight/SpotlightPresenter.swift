import AppKit
import SwiftUI

private final class SpotlightWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct SpotlightRoot: View {
    let content: AnyView
    let onResize: () -> Void

    var body: some View {
        content
            .padding(SpotlightPresenter.inset)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size) { _, _ in onResize() }
                }
            )
    }
}

@MainActor
final class SpotlightPresenter {
    static let inset: CGFloat = 24
    static let width: CGFloat = 560
    static let fieldHeight: CGFloat = 38

    weak var anchor: NSView?
    var restoresFocus = true
    private var panel: SpotlightWindow?
    private var host: NSHostingView<SpotlightRoot>?
    private weak var parent: NSWindow?
    private weak var responder: NSResponder?
    private var observers: [NSObjectProtocol] = []

    var isPresented: Bool { panel != nil }

    func present(_ content: some View, onDismiss: @escaping () -> Void) {
        guard panel == nil, let anchor, let window = anchor.window else { return }
        parent = window
        responder = window.firstResponder
        restoresFocus = true
        let host = NSHostingView(rootView: SpotlightRoot(content: AnyView(content)) { [weak self] in
            DispatchQueue.main.async { self?.reposition() }
        })
        let panel = SpotlightWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        self.host = host
        self.panel = panel
        reposition()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoresFocus = false
                    onDismiss()
                }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            },
        ]
    }

    func dismiss() {
        guard let panel else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.panel = nil
        host = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        guard let parent else { return }
        parent.makeKey()
        if restoresFocus, let responder, parent.firstResponder !== responder {
            parent.makeFirstResponder(responder)
        }
        restoresFocus = true
    }

    private func reposition() {
        guard let panel, let host, let anchor, let window = anchor.window else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = window.frame
        let top = field.midY + Self.fieldHeight / 2 + Self.inset
        var x = field.midX - size.width / 2
        x = max(frame.minX - Self.inset + 8, min(x, frame.maxX - size.width + Self.inset - 8))
        let target = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }
}
