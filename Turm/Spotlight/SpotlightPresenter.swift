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

final class SpotlightBarField: NSView {
    var onClick: () -> Void = {}
    private var hovering = false
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.chipFill.dynamicNS.setFill()
        shape.fill()
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.7) : Theme.chipStroke.dynamicNS).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let secondary = Theme.secondaryText.dynamicNS
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var x: CGFloat = 8
        if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(hierarchicalColor: secondary))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 6
        }
        let hint = "\u{2318}T" as NSString
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondary.withAlphaComponent(0.7)]
        let hintSize = hint.size(withAttributes: hintAttributes)
        let hintX = bounds.width - hintSize.width - 8
        hint.draw(at: NSPoint(x: hintX, y: (bounds.height - hintSize.height) / 2), withAttributes: hintAttributes)

        let label = "Run, jump or ? search" as NSString
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondary]
        let labelSize = label.size(withAttributes: labelAttributes)
        guard x + labelSize.width < hintX - 6 else { return }
        label.draw(at: NSPoint(x: x, y: (bounds.height - labelSize.height) / 2), withAttributes: labelAttributes)
    }
}
