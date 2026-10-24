import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TerminalPaneView: View {
    let session: TerminalSession
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatusBarPreferences.key) private var barPreferences = StatusBarPreferences()
    @AppStorage(FilePanelWidth.key) private var filesFraction = FilePanelWidth.defaultFraction
    @State private var filesDrag: CGFloat?
    @FocusedValue(\.workspace) private var workspace

    private static let horizontalInset: CGFloat = 16

    private var bar: ResolvedBar {
        ResolvedBar.resolve(session.project, preferences: barPreferences)
    }

    private var showsBar: Bool {
        barPreferences.enabled && (bar.isVisible || session.project.notice != nil)
    }

    private var isWatchingAction: Bool {
        session.runner.isWatching && session.runner.session != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let filesWidth = session.showsFiles ? FilePanelWidth.resolve(fraction: filesFraction, in: proxy.size.width) : 0
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if session.showsFiles {
                        FileSidebar(session: session)
                            .frame(width: filesWidth)
                            .background(Theme.filesSurface.color)
                    }
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        openDropped(providers)
                    }
                }
                if session.showsFiles {
                    Rectangle()
                        .fill(Theme.divider.color)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .offset(x: filesWidth)
                        .allowsHitTesting(false)
                    FilePanelResizeHandle { began in
                        filesDrag = began ? filesWidth : nil
                    } onDrag: { translation in
                        guard let filesDrag else { return }
                        filesFraction = FilePanelWidth.fraction(width: filesDrag + translation, in: proxy.size.width)
                    }
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .offset(x: filesWidth - 4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Theme.terminalBackground.color)
        }
    }

    private var terminal: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Group {
                    if let altScreen = session.altScreen {
                        AltScreenView(
                            host: altScreen,
                            isFocused: isFocused && !isWatchingAction,
                            onFocus: session.focus,
                            stillFocused: { session.isPaneFocused }
                        )
                            .id(ObjectIdentifier(altScreen))
                    } else {
                        VStack(spacing: 0) {
                            BlockListView(session: session)
                            if let progress = session.progress {
                                ProgressStrip(report: progress)
                            }
                            InputBar(session: session, isFocused: isFocused && !isWatchingAction, input: session.input)
                        }
                    }
                }
                .coordinateSpace(name: TerminalSession.paneSpace)
                .overlay {
                    if session.altScreen == nil {
                        MouseReporter(session: session)
                    }
                }
                .overlay {
                    if session.isDropTargeted {
                        Rectangle()
                            .fill(Theme.dropFill.color)
                            .overlay(Rectangle().inset(by: 0.75).stroke(Theme.dropOutline.color, lineWidth: 1.5))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if session.search.isPresented, session.altScreen == nil {
                        SearchBar(search: session.search)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isWatchingAction, let sub = session.runner.session {
                        ActionOutputPanel(runner: session.runner, session: sub) { session.popOutAction() }
                            .frame(height: max(proxy.size.height * 0.62, 140))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                if showsBar {
                    StatusBar(session: session, bar: bar)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: showsBar)
            .animation(.easeOut(duration: 0.2), value: isWatchingAction)
            .overlay {
                ActivatingClickCatcher { session.focus() }
            }
            .onChange(of: session.current?.revision) { session.search.contentChanged() }
            .onChange(of: session.blocks.count) { session.search.contentChanged() }
            .onChange(of: session.current?.isRunning) { session.search.contentChanged() }
            .onChange(of: proxy.size, initial: true) { _, size in
                report(size)
            }
            .onChange(of: isFocused, initial: true) { _, focused in
                session.setPaneFocused(focused)
            }
            .onChange(of: colorScheme, initial: true) { _, scheme in
                session.setAppearance(dark: scheme == .dark)
            }
        }
        .background(Theme.terminalBackground.color)
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            if !session.selection.listFrame.contains(tap.location) { session.selection.clear() }
            session.focus()
        })
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(
            get: { session.isDropTargeted },
            set: { session.isDropTargeted = $0 }
        )) { providers in
            Task {
                let urls = await AttachmentStore.urls(from: providers)
                if session.phase == .running {
                    session.pasteFiles(urls)
                } else if let channel = session.remoteChannel {
                    let paths = await TransferCenter.shared.upload(channel, urls)
                    session.input.attach(urls.filter { paths[$0] != nil }, paths: paths)
                } else {
                    session.input.attach(urls)
                }
            }
            return true
        }
        .overlay(alignment: .bottomTrailing) {
            if isFocused {
                TransferStack()
                    .padding(12)
            }
        }
    }

    private func openDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let workspace else { return false }
        let remote = session.isRemote
        Task { @MainActor in
            let urls = await AttachmentStore.urls(from: providers)
            for url in urls {
                if remote {
                    workspace.openRemoteFile(url.path, from: session)
                    continue
                }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { continue }
                workspace.openFile(url.path)
            }
        }
        return true
    }

    private func report(_ size: CGSize) {
        let cols = Int((size.width - Self.horizontalInset * 2) / TerminalMetrics.cellWidth)
        let rows = Int(size.height / TerminalMetrics.lineHeight)
        session.resize(cols: cols, rows: rows)
    }
}

enum TerminalMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let cellWidth: CGFloat = {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return max(width, 1)
    }()

    static let lineHeight: CGFloat = {
        let layout = NSLayoutManager()
        return max(layout.defaultLineHeight(for: font), 1)
    }()
}

private struct AltScreenView: NSViewRepresentable {
    let host: AltScreenHost
    let isFocused: Bool
    let onFocus: () -> Void
    let stillFocused: () -> Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AltContainer {
        AltContainer(host: host)
    }

    func updateNSView(_ container: AltContainer, context: Context) {
        host.view.onMouseDown = onFocus
        host.apply(dark: colorScheme == .dark)
        container.wantsFocus = isFocused
        container.stillFocused = stillFocused
        container.focusIfWanted()
    }
}

private struct ActivatingClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
    }
}

private final class CatcherView: NSView {
    var onClick: () -> Void = {}

    override var mouseDownCanMoveWindow: Bool { false }
    private var passing = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !passing, needsActivation else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
        forward(event)
    }

    private var needsActivation: Bool {
        window?.isKeyWindow == false
    }

    private func forward(_ event: NSEvent) {
        guard let content = window?.contentView, let superview = content.superview else { return }
        passing = true
        let target = content.hitTest(superview.convert(event.locationInWindow, from: nil))
        if let target, target !== self {
            target.mouseDown(with: event)
        }
        passing = false
    }
}

final class AltContainer: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    private let host: AltScreenHost
    var wantsFocus = true
    var stillFocused: () -> Bool = { false }

    init(host: AltScreenHost) {
        self.host = host
        super.init(frame: .zero)
        host.view.frame = bounds
        host.view.autoresizingMask = [.width, .height]
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AltContainer is created in code only")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    func focusIfWanted() {
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.stillFocused(), let window = self.window,
                  window.firstResponder !== self.host.view
            else { return }
            window.makeFirstResponder(self.host.view)
        }
    }
}

enum FilePanelWidth {
    static let key = "turm.filesWidthFraction"
    static let defaultFraction = 0.32
    static let range = 0.18...0.5

    static func resolve(fraction: Double, in width: CGFloat) -> CGFloat {
        let proposed = width * min(max(fraction, range.lowerBound), range.upperBound)
        let minimum = min(168, max(120, width * 0.28))
        let maximum = max(minimum, width - 240)
        return min(max(proposed, minimum), maximum)
    }

    static func fraction(width: CGFloat, in total: CGFloat) -> Double {
        guard total > 0 else { return defaultFraction }
        return min(max(width / total, range.lowerBound), range.upperBound)
    }
}

private struct FilePanelResizeHandle: View {
    var onBegan: (Bool) -> Void
    var onDrag: (CGFloat) -> Void

    var body: some View {
        FilePanelResizeRepresentable(onBegan: onBegan, onDrag: onDrag)
            .frame(width: ChromeMetrics.paneGap)
    }
}

private struct FilePanelResizeRepresentable: NSViewRepresentable {
    var onBegan: (Bool) -> Void
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.onBegan = onBegan
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.onBegan = onBegan
        view.onDrag = onDrag
    }

    final class Handle: NSView {
        var onBegan: (Bool) -> Void = { _ in }
        var onDrag: (CGFloat) -> Void = { _ in }
        private var startX: CGFloat?

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegan(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            startX = nil
            onBegan(false)
        }
    }
}
