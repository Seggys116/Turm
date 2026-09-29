import AppKit
import SwiftUI

struct TopBar: View {
    static let defaultHeight: CGFloat = 28

    @Binding var isSidebarVisible: Bool
    let placement: SidebarPlacement
    let onOpenSettings: () -> Void
    let spotlight: SpotlightPresenter
    let isSpotlightOpen: Bool
    let onSpotlight: () -> Void
    @State private var height = TopBar.defaultHeight

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Theme.topBar.color)
            .background(TitlebarChrome(
                height: $height, isSidebarVisible: $isSidebarVisible, placement: placement, onOpenSettings: onOpenSettings,
                spotlight: spotlight, isSpotlightOpen: isSpotlightOpen, onSpotlight: onSpotlight
            ))
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
    let spotlight: SpotlightPresenter
    let isSpotlightOpen: Bool
    let onSpotlight: () -> Void

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
        view.search.onClick = onSpotlight
        view.spotlightOpen = isSpotlightOpen
        view.search.isHidden = isSpotlightOpen || view.search.frame.width == 0
        spotlight.anchor = view.search
    }

    final class ChromeView: NSView {
        var onHeight: (CGFloat) -> Void = { _ in }
        var onToggle: () -> Void = {}
        var onSettings: () -> Void = {}

        private static let buttonSize = NSSize(width: 30, height: 24)
        private static let trafficLightGap: CGFloat = 12
        private static let buttonGap: CGFloat = 2
        private static let searchHeight: CGFloat = 22
        private static let searchWidth: ClosedRange<CGFloat> = 180...380

        private let toggle = NSButton()
        private let settings = NSButton()
        let search = SpotlightBarField()
        var spotlightOpen = false
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
            search.removeFromSuperview()
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

            if search.superview !== container { container.addSubview(search) }
            let leftEdge = settings.frame.maxX + 16
            let width = min(Self.searchWidth.upperBound, max(Self.searchWidth.lowerBound, container.bounds.width * 0.36))
            var x = ((container.bounds.width - width) / 2).rounded()
            x = max(x, leftEdge)
            let fitted = min(width, container.bounds.width - x - 12)
            let fits = fitted >= Self.searchWidth.lowerBound * 0.75
            search.frame = fits
                ? NSRect(x: x, y: (close.frame.midY - Self.searchHeight / 2).rounded(), width: fitted, height: Self.searchHeight)
                : .zero
            search.isHidden = !fits || spotlightOpen
            search.needsDisplay = true
        }
    }
}
