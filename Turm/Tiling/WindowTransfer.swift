import AppKit
import SwiftUI

@MainActor
final class WindowTransfer {
    static let shared = WindowTransfer()
    static let windowID = "turm.main"

    struct Pending {
        let shell: ShellTransfer
        let frame: NSRect
    }

    private var queue: [Pending] = []

    func enqueue(_ shell: ShellTransfer, frame: NSRect) {
        queue.append(Pending(shell: shell, frame: frame))
    }

    func take() -> Pending? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    var pendingSessions: [TerminalSession] {
        queue.flatMap { $0.shell.sessions.values }
    }

    static func frame(size: CGSize, at point: NSPoint) -> NSRect {
        var frame = NSRect(x: point.x - 80, y: point.y + 12 - size.height, width: size.width, height: size.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
}

struct WindowPlacer: NSViewRepresentable {
    let frame: NSRect?

    func makeNSView(context: Context) -> PlacerView {
        let view = PlacerView()
        view.target = frame
        return view
    }

    func updateNSView(_ view: PlacerView, context: Context) {}

    final class PlacerView: NSView {
        var target: NSRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let target, let window else { return }
            self.target = nil
            window.setFrame(target, display: true)
            // SwiftUI cascades new windows after they attach
            DispatchQueue.main.async { window.setFrame(target, display: true) }
        }
    }
}

@MainActor
final class TearOffPanel {
    private var panel: NSPanel?
    private var host: NSHostingView<TearOffLabel>?

    func show(_ title: String, at point: NSPoint) {
        let (panel, host) = existing ?? make()
        host.rootView = TearOffLabel(title: title)
        let size = host.fittingSize
        panel.setFrame(NSRect(x: point.x + 14, y: point.y - 10 - size.height, width: size.width, height: size.height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    isolated deinit {
        panel?.close()
    }

    private var existing: (NSPanel, NSHostingView<TearOffLabel>)? {
        guard let panel, let host else { return nil }
        return (panel, host)
    }

    private func make() -> (NSPanel, NSHostingView<TearOffLabel>) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        let host = NSHostingView(rootView: TearOffLabel(title: ""))
        panel.contentView = host
        self.panel = panel
        self.host = host
        return (panel, host)
    }
}

struct TearOffLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: ShellSidebar.corner))
        .overlay(RoundedRectangle(cornerRadius: ShellSidebar.corner).stroke(Theme.chipStroke.color, lineWidth: 1))
        .padding(8)
    }
}
