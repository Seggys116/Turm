import AppKit
import SwiftUI

struct StatusBar: View {
    var body: some View {
        Color.clear
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Theme.statusBar.color)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider.color).frame(height: 1)
            }
    }
}

struct TopBar: View {
    static let defaultHeight: CGFloat = 28

    @Binding var isSidebarVisible: Bool
    let placement: SidebarPlacement
    let onOpenSettings: () -> Void
    @State private var height = TopBar.defaultHeight

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Theme.topBar.color)
            .background(TitlebarChrome(height: $height, isSidebarVisible: $isSidebarVisible, placement: placement, onOpenSettings: onOpenSettings))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider.color).frame(height: 1)
            }
    }
}

/// The window's title bar layer takes mouse events above SwiftUI content, so the toggle lives beside the traffic lights.
private struct TitlebarChrome: NSViewRepresentable {
    @Binding var height: CGFloat
    @Binding var isSidebarVisible: Bool
    let placement: SidebarPlacement
    let onOpenSettings: () -> Void

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        update(view)
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        update(view)
    }

    private func update(_ view: ChromeView) {
        view.onHeight = { height = $0 }
        view.onToggle = { withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() } }
        view.onSettings = onOpenSettings
        view.setSidebar(visible: isSidebarVisible, placement: placement)
    }

    final class ChromeView: NSView {
        var onHeight: (CGFloat) -> Void = { _ in }
        var onToggle: () -> Void = {}
        var onSettings: () -> Void = {}

        private static let buttonSize = NSSize(width: 30, height: 24)
        private static let trafficLightGap: CGFloat = 12
        private static let buttonGap: CGFloat = 2

        private let toggle = NSButton()
        private let settings = NSButton()
        private var observers: [NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            toggle.imagePosition = .imageOnly
            toggle.bezelStyle = .texturedRounded
            toggle.showsBorderOnlyWhileMouseInside = true
            toggle.contentTintColor = .secondaryLabelColor
            toggle.target = self
            toggle.action = #selector(pressed)

            settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            settings.imagePosition = .imageOnly
            settings.bezelStyle = .texturedRounded
            settings.showsBorderOnlyWhileMouseInside = true
            settings.contentTintColor = .secondaryLabelColor
            settings.target = self
            settings.action = #selector(openSettings)
            settings.toolTip = "Settings"
            settings.setAccessibilityLabel("Settings")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ChromeView is created in code only")
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setSidebar(visible: Bool, placement: SidebarPlacement) {
            toggle.image = NSImage(systemSymbolName: placement.symbol, accessibilityDescription: "Toggle \(placement.noun)")
            toggle.toolTip = visible ? "Hide \(placement.noun)" : "Show \(placement.noun)"
            toggle.setAccessibilityLabel("Toggle \(placement.noun)")
        }

        @objc private func pressed() {
            onToggle()
        }

        @objc private func openSettings() {
            onSettings()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            toggle.removeFromSuperview()
            settings.removeFromSuperview()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutChrome() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.layoutChrome() }
        }

        private func layoutChrome() {
            guard let window, let content = window.contentView,
                  let close = window.standardWindowButton(.closeButton), !close.isHidden,
                  let container = close.superview
            else { return }
            let frame = content.convert(close.convert(close.bounds, to: nil), from: nil)
            let fromTop = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
            let target = (fromTop * 2).rounded()
            if target > 0 { onHeight(target) }

            if toggle.superview !== container { container.addSubview(toggle) }
            if settings.superview !== container { container.addSubview(settings) }
            let anchor = window.standardWindowButton(.zoomButton)?.frame.maxX ?? close.frame.maxX
            toggle.frame = NSRect(
                x: anchor + Self.trafficLightGap,
                y: (close.frame.midY - Self.buttonSize.height / 2).rounded(),
                width: Self.buttonSize.width,
                height: Self.buttonSize.height
            )
            settings.frame = toggle.frame.offsetBy(dx: Self.buttonSize.width + Self.buttonGap, dy: 0)
        }
    }
}
