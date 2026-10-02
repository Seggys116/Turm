import SwiftUI
import UniformTypeIdentifiers

struct TerminalPaneView: View {
    let session: TerminalSession
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatusBarPreferences.key) private var barPreferences = StatusBarPreferences()

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
            VStack(spacing: 0) {
                Group {
                    if let altScreen = session.altScreen {
                        AltScreenView(host: altScreen, isFocused: isFocused && !isWatchingAction)
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
                    let paths = await channel.upload(urls)
                    session.input.attach(urls.filter { paths[$0] != nil }, paths: paths)
                } else {
                    session.input.attach(urls)
                }
            }
            return true
        }
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
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AltContainer {
        AltContainer(host: host)
    }

    func updateNSView(_ container: AltContainer, context: Context) {
        host.apply(dark: colorScheme == .dark)
        container.wantsFocus = isFocused
        container.focusIfWanted()
    }
}

final class AltContainer: NSView {
    private let host: AltScreenHost
    var wantsFocus = true

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
            guard let self, self.wantsFocus, let window = self.window,
                  window.firstResponder !== self.host.view
            else { return }
            window.makeFirstResponder(self.host.view)
        }
    }
}
