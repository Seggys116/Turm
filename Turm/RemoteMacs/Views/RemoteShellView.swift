import AppKit
import SwiftUI
import TurmCore

struct RemoteShellView: View {
    let connection: RemoteMacConnection
    let shellID: UUID
    @State private var session: RemoteMacSession?

    var body: some View {
        Group {
            if let session {
                RemoteSessionView(connection: connection, session: session)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if session == nil { session = connection.session(for: shellID) }
        }
        .onDisappear {
            session?.close()
            session = nil
        }
    }
}

private struct RemoteSessionView: View {
    let connection: RemoteMacConnection
    let session: RemoteMacSession
    @State private var selection = BlockSelection()
    @State private var driver = SelectionDriver()
    @State private var position = ScrollPosition()
    @State private var hoveredLink: URL?
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let bottom = "turm.remote.bottom"
    private static let listSpace = "turm.remote.list"
    private static let inset: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            if let banner = session.banner {
                RemoteBannerView(banner: banner) { session.dismissNotice() }
            }
            if let advice = connection.updateAdvice {
                RemoteBannerView(banner: .notice(advice), dismiss: nil)
            }
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    session.setViewport(CGSize(width: $0.width - Self.inset, height: $0.height))
                }
            if session.fullScreen == nil { commandBar }
        }
        .background(Theme.terminalBackground.color)
        .onAppear {
            session.setAppearance(dark: colorScheme == .dark)
            selection.source = { MainActor.assumeIsolated { session.blocks.map { SearchDocument(block: $0) } } }
        }
        .onChange(of: colorScheme) { session.setAppearance(dark: colorScheme == .dark) }
        .navigationTitle(session.title)
        .navigationSubtitle(session.subtitle)
        .toolbar {
            ToolbarItemGroup {
                if session.branch != nil { RemoteBranchMenu(session: session) }
                Toggle(isOn: Binding(get: { session.fitsWindow }, set: { session.setFitsWindow($0) })) {
                    Label("Fit to This Window", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button)
                .help("Resize the shell on the Mac to fit this window")
                Button {
                    session.reveal(session.directory)
                } label: {
                    Label("Reveal in Finder on Mac", systemImage: "folder")
                }
                .help("Reveal in Finder on \(session.macName)")
                .disabled(session.directory.isEmpty || session.link != .connected)
                shortcutsMenu
            }
        }
        .sheet(item: Bindable(session).editor) { target in
            RemoteShortcutEditor(session: session, connection: connection, target: target)
        }
    }

    private var shortcutsMenu: some View {
        Menu {
            Button(session.directoryShortcut(at: session.directory) == nil ? "Save Folder as Shortcut..." : "Edit Folder Shortcut...") {
                session.editor = RemoteShortcutTarget(kind: .directory(session.directory))
            }
            .disabled(session.directory.isEmpty)
            Divider()
            ForEach(session.shortcuts.filter { $0.kind != .file }) { shortcut in
                Menu(shortcut.name.isEmpty ? shortcut.token : shortcut.token + "  " + shortcut.name) {
                    if shortcut.kind == .directory {
                        Button("Go to Folder") { session.changeDirectory(to: shortcut.value) }
                            .disabled(session.phase != .ready)
                    } else {
                        Button("Run Command") { session.submit(shortcut.value) }
                            .disabled(session.phase != .ready)
                    }
                    Button("Remove Shortcut", role: .destructive) { session.removeShortcut(shortcut) }
                }
            }
        } label: {
            Label("Shortcuts", systemImage: "bolt")
        }
        .help("Shortcuts on \(session.macName)")
        .disabled(session.link != .connected)
    }

    @ViewBuilder
    private var content: some View {
        if let host = session.fullScreen {
            RemoteAltScreen(host: host)
                .id(ObjectIdentifier(host))
        } else {
            blockList
        }
    }

    private var blockList: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.blocks) { block in
                        RemoteBlockView(block: block, session: session, selection: selection)
                            .id(block.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .coordinateSpace(name: BlockSelection.space)
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Self.listSpace)).origin } action: {
                    driver.contentOrigin = $0
                }
                .onContinuousHover(coordinateSpace: .named(BlockSelection.space)) { phase in
                    var link: URL?
                    if case .active(let point) = phase { link = selection.link(at: point) }
                    if link != hoveredLink { hoveredLink = link }
                }
            }
            .coordinateSpace(name: Self.listSpace)
            .contentShape(Rectangle())
            .gesture(selectionGesture)
            .pointerStyle(hoveredLink != nil ? PointerStyle.link : nil)
            .help(hoveredLink?.absoluteString ?? "")
            .background(SelectionResponder(selection: selection))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { selection.listFrame = $0 }
            .squareScrollbar(position: $position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { old, metrics in
                driver.metrics = metrics
                if metrics.viewport < old.viewport, isPinned(old) { reader.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.blocks.count) { reader.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: session.runningBlock?.revision) { followOutput(reader) }
        }
    }

    private func isPinned(_ metrics: ScrollMetrics) -> Bool {
        metrics.offset >= metrics.content - metrics.viewport - TerminalMetrics.lineHeight * 2
    }

    private func followOutput(_ reader: ScrollViewProxy) {
        guard isPinned(driver.metrics), !driver.active else { return }
        reader.scrollTo(Self.bottom, anchor: .bottom)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if !driver.active {
                    guard !NSEvent.modifierFlags.contains(.control) else { return }
                    driver.active = true
                    driver.moved = false
                    driver.clicks = NSApp.currentEvent?.clickCount ?? 1
                    selection.press(
                        at: contentPoint(value.startLocation), clicks: driver.clicks,
                        extend: NSEvent.modifierFlags.contains(.shift)
                    )
                }
                guard driver.active else { return }
                driver.pointerX = value.location.x
                driver.viewportY = value.location.y
                if !driver.moved, hypot(value.translation.width, value.translation.height) > 3 { driver.moved = true }
                if driver.moved {
                    selection.drag(to: contentPoint(value.location))
                    startAutoscroll()
                }
            }
            .onEnded { value in
                driver.task?.cancel()
                driver.task = nil
                if driver.active, !driver.moved, driver.clicks == 1, let url = selection.link(at: contentPoint(value.location)) {
                    NSWorkspace.shared.open(url)
                }
                if driver.active { selection.hasSelection ? selection.claimFocus() : selection.releaseFocus() }
                driver.active = false
            }
    }

    private func contentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - driver.contentOrigin.x, y: point.y - driver.contentOrigin.y)
    }

    private func startAutoscroll() {
        guard driver.task == nil else { return }
        let driver = driver
        let selection = selection
        driver.task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let metrics = driver.metrics
                let overshoot = driver.viewportY < 0 ? driver.viewportY : max(driver.viewportY - metrics.viewport, 0)
                guard overshoot != 0 else { continue }
                let step = min(max(overshoot * 0.4, -48), 48)
                let limit = max(metrics.content - metrics.viewport, 0)
                let target = min(max(metrics.offset + step, 0), limit)
                guard target != metrics.offset else { continue }
                position.scrollTo(y: target)
                driver.contentOrigin.y -= target - metrics.offset
                driver.metrics.offset = target
                selection.drag(to: CGPoint(x: driver.pointerX - driver.contentOrigin.x, y: driver.viewportY - driver.contentOrigin.y))
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            TextField(session.phase == .running ? "Send input to the running program" : "Run a command", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .focused($commandFocused)
                .onSubmit(send)
                .disabled(!session.acceptsInput)
            if session.phase == .running {
                Button("Interrupt") { session.interrupt() }
                    .keyboardShortcut("c", modifiers: .control)
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!session.acceptsInput)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.inputBackground.color)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.subtleDivider.color).frame(height: 1)
        }
    }

    private func send() {
        guard session.acceptsInput else { return }
        if session.phase == .running {
            session.input(Data((command.replacingOccurrences(of: "\n", with: "\r") + "\r").utf8))
        } else {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            session.submit(command)
        }
        command = ""
    }
}

private struct RemoteBannerView: View {
    let banner: RemoteSessionBanner
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            switch banner {
            case .progress(let text):
                ProgressView()
                    .controlSize(.small)
                Text(text)
            case .problem(let text, let systemImage):
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.failure.color)
                Text(text)
            case .notice(let text):
                Image(systemName: "info.circle")
                Text(text)
            }
            Spacer(minLength: 0)
            if let dismiss, case .notice = banner {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chipFill.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.subtleDivider.color).frame(height: 1)
        }
    }
}

private struct RemoteBranchMenu: View {
    let session: RemoteMacSession
    @State private var names: [String] = []

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { name in
                Button {
                    switchTo(name)
                } label: {
                    if name == session.branch {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Label(session.branch ?? "Branch", systemImage: "arrow.triangle.branch")
        }
        .help("Switch branch on \(session.macName)")
        .task(id: session.link == .connected ? session.branch : nil) {
            guard session.link == .connected, let loaded = try? await session.branches() else { return }
            names = loaded.names
        }
    }

    private func switchTo(_ name: String) {
        session.perform { connection in
            if let failure = try await session.switchBranch(to: name) { connection.report(failure) }
        }
    }
}

private struct RemoteAltScreen: NSViewRepresentable {
    let host: AltScreenHost
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AltContainer {
        AltContainer(host: host)
    }

    func updateNSView(_ container: AltContainer, context: Context) {
        host.apply(dark: colorScheme == .dark)
        container.focusIfWanted()
    }
}
