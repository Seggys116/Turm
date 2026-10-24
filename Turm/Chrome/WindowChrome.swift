import AppKit
import SwiftUI

struct WindowControlActions {
    var windowProvider: () -> NSWindow?

    static let noop = WindowControlActions(windowProvider: { nil })

    func close() { windowProvider()?.performClose(nil) }
    func miniaturize() { windowProvider()?.performMiniaturize(nil) }
    func zoom() { windowProvider()?.performZoom(nil) }
}

struct WindowControlsCluster: View {
    var isKey: Bool
    var isHovering: Bool
    var actions: WindowControlActions = .noop

    private static let close = Color(red: 1, green: 0.373, blue: 0.341)
    private static let minimize = Color(red: 0.996, green: 0.737, blue: 0.180)
    private static let zoom = Color(red: 0.157, green: 0.784, blue: 0.251)
    private static let inactive = Color(red: 0.55, green: 0.55, blue: 0.53)

    var body: some View {
        HStack(spacing: ChromeMetrics.trafficLightSpacing) {
            dot(color: Self.close, glyph: "xmark", help: "Close", action: actions.close)
            dot(color: Self.minimize, glyph: "minus", help: "Minimize", action: actions.miniaturize)
            dot(color: Self.zoom, glyph: "plus", help: "Zoom", action: actions.zoom)
        }
        .frame(width: ChromeMetrics.trafficLightClusterWidth, height: ChromeMetrics.trafficLightDiameter, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func dot(color: Color, glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isKey ? color : Self.inactive)
                if isHovering {
                    Image(systemName: glyph)
                        .font(.system(size: ChromeMetrics.trafficLightDiameter * 0.6, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: ChromeMetrics.trafficLightDiameter, height: ChromeMetrics.trafficLightDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The traffic lights drawn in the sidebar. AppKit's own buttons stay in the window, hidden,
/// because a full-size content view would otherwise show a second set over the sidebar.
struct WindowControls: View {
    var windowProvider: () -> NSWindow? = { NSApp.keyWindow }

    @State private var hostedWindow: NSWindow?
    @State private var isKey = true
    @State private var isHovering = false

    var body: some View {
        WindowControlsCluster(
            isKey: isKey,
            isHovering: isHovering,
            actions: WindowControlActions(windowProvider: { hostedWindow ?? windowProvider() })
        )
        .onHover { isHovering = $0 }
        .background(WindowKeyStateReader(window: $hostedWindow, isKey: $isKey).frame(width: 0, height: 0))
        .padding(.leading, ChromeMetrics.trafficLightLeadingInset)
        .padding(.top, ChromeMetrics.trafficLightTopInset)
    }
}

private struct WindowKeyStateReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onWindowChange = { newWindow in
            window = newWindow
            isKey = newWindow?.isKeyWindow ?? true
        }
        view.onKeyChange = { isKey = $0 }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {}

    final class ObservingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        var onKeyChange: ((Bool) -> Void)?
        private var becomeKeyObserver: NSObjectProtocol?
        private var resignKeyObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            detach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            onWindowChange?(window)
            guard let window else { return }
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onKeyChange?(true) } }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onKeyChange?(false) } }
        }

        private func detach() {
            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            becomeKeyObserver = nil
            resignKeyObserver = nil
        }
    }
}

/// Makes the SwiftUI window borderless without giving up the system close, minimize and zoom actions.
/// The buttons are hidden on the next turn as well: AppKit puts them back when the window is restyled.
struct WindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView()
    }

    func updateNSView(_ nsView: SurfaceView, context: Context) {}

    final class SurfaceView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            hideSystemButtons(of: window)
            DispatchQueue.main.async { [weak window] in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    window.standardWindowButton(.closeButton)?.isHidden = true
                    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                }
            }
        }

        private func hideSystemButtons(of window: NSWindow) {
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}

struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

struct SidebarResizeHandle: View {
    var width: CGFloat
    var onWidth: (CGFloat) -> Void

    var body: some View {
        SidebarResizeRepresentable(width: width, onWidth: onWidth)
            .frame(width: ChromeMetrics.sidebarResizeHandleWidth)
    }
}

private struct SidebarResizeRepresentable: NSViewRepresentable {
    var width: CGFloat
    var onWidth: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onWidth = onWidth
        view.currentWidth = { width }
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onWidth = onWidth
        view.currentWidth = { width }
    }

    final class HandleView: NSView {
        var onWidth: (CGFloat) -> Void = { _ in }
        var currentWidth: () -> CGFloat = { ChromeMetrics.sidebarDefaultWidth }
        private var startWidth: CGFloat?
        private var startX: CGFloat?

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.insetBy(dx: -8, dy: 0).contains(local) ? self : nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds.insetBy(dx: -8, dy: 0), cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startWidth = currentWidth()
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startWidth, let startX else { return }
            onWidth(SidebarWidthPreference.clamped(startWidth + event.locationInWindow.x - startX))
        }

        override func mouseUp(with event: NSEvent) {
            startWidth = nil
            startX = nil
        }
    }
}

struct SidebarEdgeCatcher: NSViewRepresentable {
    var hotZoneWidth: CGFloat
    var onHover: (Bool) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onHover = onHover
        view.onClick = onClick
        view.hotZoneWidth = hotZoneWidth
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onHover = onHover
        view.onClick = onClick
        view.hotZoneWidth = hotZoneWidth
    }

    final class Catcher: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onClick: () -> Void = {}
        var hotZoneWidth: CGFloat = 8
        private var tracking: NSTrackingArea?
        private var inside = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            inside = true
            onHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            inside = false
            onHover(false)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            onClick()
        }
    }
}

struct SidebarPanelTracker: NSViewRepresentable {
    var isActive: Bool
    var onInside: (Bool) -> Void
    var onClickOutside: () -> Void

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        view.isActive = isActive
        view.onInside = onInside
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ view: Tracker, context: Context) {
        if view.isActive, !isActive { view.noteInactive() }
        view.isActive = isActive
        view.onInside = onInside
        view.onClickOutside = onClickOutside
    }

    final class Tracker: NSView {
        var isActive = false
        var onInside: (Bool) -> Void = { _ in }
        var onClickOutside: () -> Void = {}
        private var monitors: [Any] = []
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            })
        }

        deinit {
            monitors.forEach(NSEvent.removeMonitor)
        }

        func noteInactive() {
            inside = false
        }

        private func handle(_ event: NSEvent) {
            guard isActive, let window, event.window === window else { return }
            let local = convert(event.locationInWindow, from: nil)
            let over = containsPointer(local)
            if event.type != .mouseMoved {
                if !over {
                    inside = false
                    onClickOutside()
                }
                return
            }
            guard over != inside else { return }
            inside = over
            onInside(over)
        }

        private func containsPointer(_ local: CGPoint) -> Bool {
            var rect = bounds
            rect.origin.x -= 20
            rect.size.width += 20
            rect.origin.y -= 12
            rect.size.height += 24
            return rect.contains(local)
        }
    }
}

struct HoverEdgeDetector: NSViewRepresentable {
    var hotZoneWidth: CGFloat
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHoverChanged = onHoverChanged
        view.hotZoneWidth = hotZoneWidth
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onHoverChanged = onHoverChanged
        view.hotZoneWidth = hotZoneWidth
    }

    final class HoverTrackingView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        var hotZoneWidth: CGFloat = 0 {
            didSet {
                guard hotZoneWidth != oldValue, let window, let event = window.currentEvent else { return }
                handle(event)
            }
        }

        private var isInside = false
        private var monitors: [Any] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            monitors.forEach(NSEvent.removeMonitor)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detachMonitors()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            })
        }

        private func detachMonitors() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }

        private func handle(_ event: NSEvent) {
            guard let window else { return }
            guard event.window === window else {
                leave()
                return
            }
            let inside = event.locationInWindow.x >= 0 && event.locationInWindow.x <= hotZoneWidth
            guard inside != isInside else { return }
            isInside = inside
            onHoverChanged?(inside)
        }

        private func leave() {
            guard isInside else { return }
            isInside = false
            onHoverChanged?(false)
        }
    }
}

struct SpotlightAnchor: NSViewRepresentable {
    let presenter: SpotlightPresenter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.presenter = presenter
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.presenter = presenter
        view.presenter?.anchor = view
    }

    final class AnchorView: NSView {
        weak var presenter: SpotlightPresenter?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presenter?.anchor = self
        }
    }
}
