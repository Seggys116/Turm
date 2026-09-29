import AppKit
import SwiftUI

extension View {
    /// Shows an animated menu attached above or below this view.
    func anchoredMenu<Menu: View>(isOpen: Binding<Bool>, @ViewBuilder content: @escaping () -> Menu) -> some View {
        modifier(PopoverMenuModifier(isOpen: isOpen, opensOnRightClick: false, menu: { AnyView(content()) }))
    }

    /// Shows an animated menu at the pointer when this view is right-clicked.
    func pointerMenu<Menu: View>(isOpen: Binding<Bool>, @ViewBuilder content: @escaping () -> Menu) -> some View {
        modifier(PopoverMenuModifier(isOpen: isOpen, opensOnRightClick: true, menu: { AnyView(content()) }))
    }
}

private struct PopoverMenuModifier: ViewModifier {
    @Binding var isOpen: Bool
    let opensOnRightClick: Bool
    let menu: () -> AnyView
    @State private var controller = MenuController()

    func body(content: Content) -> some View {
        content
            .background(FrameProbe(box: controller.chip))
            .onChange(of: isOpen) { _, open in
                if open {
                    controller.onDismiss = { isOpen = false }
                    controller.present(menu(), placement: opensOnRightClick ? .pointer(controller.pointer) : .anchored)
                } else {
                    controller.dismiss()
                }
            }
            .onAppear {
                guard opensOnRightClick else { return }
                controller.installTrigger {
                    isOpen = false
                    DispatchQueue.main.async { isOpen = true }
                }
            }
            .onDisappear {
                controller.teardown()
                isOpen = false
            }
    }
}

private enum MenuPlacement {
    case anchored
    case pointer(NSPoint)
}

@Observable
private final class MenuPresentation {
    var shown = false
    var anchor = UnitPoint.bottomLeading
}

private let menuInset: CGFloat = 18

private struct MenuRoot: View {
    let presentation: MenuPresentation
    let content: AnyView
    let onResize: () -> Void

    var body: some View {
        content
            .scaleEffect(presentation.shown ? 1 : 0.6, anchor: presentation.anchor)
            .opacity(presentation.shown ? 1 : 0)
            .animation(.spring(duration: 0.34, bounce: 0.38), value: presentation.shown)
            .padding(menuInset)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size) { _, _ in onResize() }
                }
            )
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MenuHostingView: NSHostingView<MenuRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class MenuController {
    let chip = ViewBox()
    var onDismiss: () -> Void = {}
    private let presentation = MenuPresentation()
    private var panel: MenuPanel?
    private var host: MenuHostingView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var trigger: Any?
    private var generation = 0
    private var placement = MenuPlacement.anchored
    private(set) var pointer = NSPoint.zero

    func installTrigger(_ open: @escaping () -> Void) {
        if let trigger { NSEvent.removeMonitor(trigger) }
        trigger = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            nonisolated(unsafe) let captured = event
            MainActor.assumeIsolated {
                guard let self, self.chip.contains(captured) else { return }
                self.pointer = NSEvent.mouseLocation
                open()
            }
            return event
        }
    }

    func present(_ content: AnyView, placement: MenuPlacement) {
        guard let window = chip.view?.window else { return }
        teardown()
        self.placement = placement
        generation += 1
        presentation.shown = false
        let root = MenuRoot(presentation: presentation, content: content) { [weak self] in
            DispatchQueue.main.async { self?.reposition() }
        }
        let host = MenuHostingView(rootView: root)
        let panel = MenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        self.host = host
        self.panel = panel
        reposition()
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        installMonitors(window: window)
        DispatchQueue.main.async { [presentation] in presentation.shown = true }
    }

    func dismiss() {
        guard panel != nil else { return }
        removeMonitors()
        presentation.shown = false
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, token == generation else { return }
            closePanel()
        }
    }

    func teardown() {
        if let trigger { NSEvent.removeMonitor(trigger) }
        trigger = nil
        removeMonitors()
        closePanel()
    }

    private func closePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        host = nil
    }

    private func reposition() {
        guard let panel, let host, let chipView = chip.view, let window = chipView.window else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let chipRect = window.convertToScreen(chipView.convert(chipView.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? chipRect
        let margin: CGFloat = 8
        let surface = CGSize(width: size.width - 2 * menuInset, height: size.height - 2 * menuInset)
        let origin: CGPoint
        let anchor: UnitPoint
        switch placement {
        case .anchored:
            let gap: CGFloat = 6
            let room = (
                above: visible.maxY - chipRect.maxY - gap - margin,
                below: chipRect.minY - visible.minY - gap - margin
            )
            let goUp = room.above >= surface.height || (room.below < surface.height && room.above >= room.below)
            let x = max(min(chipRect.minX, visible.maxX - margin - surface.width), visible.minX + margin)
            origin = CGPoint(x: x, y: goUp ? chipRect.maxY + gap : chipRect.minY - gap - surface.height)
            anchor = goUp ? .bottomLeading : .topLeading
        case .pointer(let point):
            let opensLeft = point.x + surface.width > visible.maxX - margin
            let opensUp = point.y - surface.height < visible.minY + margin
            let x = opensLeft ? point.x - surface.width : point.x
            let y = opensUp ? point.y : point.y - surface.height
            origin = CGPoint(x: max(x, visible.minX + margin), y: min(y, visible.maxY - margin - surface.height))
            anchor = UnitPoint(x: opensLeft ? 1 : 0, y: opensUp ? 1 : 0)
        }
        let frame = NSRect(x: origin.x - menuInset, y: origin.y - menuInset, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if presentation.anchor != anchor { presentation.anchor = anchor }
    }

    private func installMonitors(window: NSWindow) {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            nonisolated(unsafe) let captured = event
            let consumed = MainActor.assumeIsolated { self?.handle(captured) ?? false }
            return consumed ? nil : event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss() }
        }
        monitors = [local, global].compactMap { $0 }
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDismiss() }
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            onDismiss()
            return true
        }
        if event.window === panel { return false }
        if case .anchored = placement, chip.contains(event) { return false }
        onDismiss()
        return false
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

private final class ViewBox {
    weak var view: NSView?

    func contains(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, event.window === window else { return false }
        return view.convert(view.bounds, to: nil).contains(event.locationInWindow)
    }
}

private struct FrameProbe: NSViewRepresentable {
    let box: ViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}

private let menuPadding: CGFloat = 4
private let menuRadius: CGFloat = 9

struct MenuSurface<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(menuPadding)
            .frame(width: width, alignment: .leading)
            .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: menuRadius))
            .overlay(RoundedRectangle(cornerRadius: menuRadius).stroke(Theme.chipStroke.color, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }
}

struct MenuRow: View {
    let title: String
    var symbol: String?
    var detail: String?
    var isCurrent = false
    var isDestructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                    } else if isCurrent {
                        Image(systemName: "checkmark")
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(isDestructive ? Theme.removed.color : Theme.secondaryText.color)
                .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isDestructive ? Theme.removed.color : Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.color)
                }
                if isCurrent && symbol != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.color)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: menuRadius - menuPadding)
                    .fill(hovering ? Color.accentColor.opacity(0.28) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

func copyToPasteboard(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
}
