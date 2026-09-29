import AppKit
import SwiftUI

extension View {
    func chipMenu<Menu: View>(isOpen: Binding<Bool>, @ViewBuilder content: @escaping () -> Menu) -> some View {
        modifier(ChipMenuModifier(isOpen: isOpen, menu: { AnyView(content()) }))
    }
}

private struct ChipMenuModifier: ViewModifier {
    @Binding var isOpen: Bool
    let menu: () -> AnyView
    @State private var controller = MenuController()

    func body(content: Content) -> some View {
        content
            .background(FrameProbe(box: controller.chip))
            .onChange(of: isOpen) { _, open in
                if open {
                    controller.onDismiss = { isOpen = false }
                    controller.present(menu())
                } else {
                    controller.dismiss()
                }
            }
            .onDisappear {
                controller.teardown()
                isOpen = false
            }
    }
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
    private var generation = 0

    func present(_ content: AnyView) {
        guard let window = chip.view?.window else { return }
        teardown()
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
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        let surface = CGSize(width: size.width - 2 * menuInset, height: size.height - 2 * menuInset)
        let room = (
            above: visible.maxY - chipRect.maxY - gap - margin,
            below: chipRect.minY - visible.minY - gap - margin
        )
        let goUp = room.above >= surface.height || (room.below < surface.height && room.above >= room.below)
        var surfaceX = chipRect.minX
        surfaceX = min(surfaceX, visible.maxX - margin - surface.width)
        surfaceX = max(surfaceX, visible.minX + margin)
        let surfaceY = goUp ? chipRect.maxY + gap : chipRect.minY - gap - surface.height
        let frame = NSRect(x: surfaceX - menuInset, y: surfaceY - menuInset, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        let anchor: UnitPoint = goUp ? .bottomLeading : .topLeading
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
        if event.window === panel || chip.contains(event) { return false }
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
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text.color)
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

struct PathMenu: View {
    let path: String
    let close: () -> Void

    var body: some View {
        MenuSurface(width: 220) {
            MenuRow(title: "Open in Finder", symbol: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                close()
            }
            MenuRow(title: "Copy Path", symbol: "doc.on.doc") {
                copy(path)
                close()
            }
            MenuRow(title: "Copy Folder Name", symbol: "textformat") {
                copy((path as NSString).lastPathComponent)
                close()
            }
        }
    }
}

struct BranchMenu: View {
    let session: TerminalSession
    let close: () -> Void
    @State private var branches: [String]?
    @State private var error: String?
    @State private var switching: String?

    private static let rowHeight: CGFloat = 24
    private static let maxRows = 8

    var body: some View {
        MenuSurface(width: 260) {
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.removed.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.vertical, 2)
            }
            list
            Divider().padding(.vertical, 2)
            MenuRow(title: "Copy Branch Name", symbol: "doc.on.doc") {
                if let name = session.git?.branch { copy(name) }
                close()
            }
        }
        .task { branches = await GitInspector.branches(in: session.directory) }
    }

    @ViewBuilder
    private var list: some View {
        if let branches {
            let rows = CGFloat(min(max(branches.count, 1), Self.maxRows))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(branches, id: \.self) { name in
                        MenuRow(
                            title: name,
                            detail: switching == name ? "switching" : nil,
                            isCurrent: name == session.git?.branch
                        ) { switchTo(name) }
                    }
                }
            }
            .frame(height: rows * Self.rowHeight)
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        }
    }

    private func switchTo(_ name: String) {
        guard name != session.git?.branch, switching == nil else { return }
        switching = name
        error = nil
        Task {
            let failure = await session.switchBranch(to: name)
            switching = nil
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}

private func copy(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
}
