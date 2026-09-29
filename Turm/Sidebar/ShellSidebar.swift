import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShellSidebar: View {
    static let width: CGFloat = 240
    static let stripHeight: CGFloat = 32
    private static let gap: CGFloat = 6
    private static let rowHeight: CGFloat = 28
    private static let chipHeight: CGFloat = 24
    private static let chipWidthRange: ClosedRange<CGFloat> = 72...200
    /// Row padding, indicator and the spacing after it.
    private static let chipChrome: CGFloat = 34
    private static let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let countFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let stripSearchWidth: CGFloat = 150

    let workspace: Workspace
    let placement: SidebarPlacement
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var dropTargetID: UUID?
    @State private var stripPosition = ScrollPosition(edge: .leading)
    @State private var stripOffset: CGFloat = 0
    @State private var stripOverflow: CGFloat = 0

    var body: some View {
        Group {
            if placement == .top {
                strip
            } else {
                column
            }
        }
        .onOutsideFieldClick(isActive: searchFocused) { searchFocused = false }
    }

    private var column: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                searchField
                newShellButton
            }
            .padding(8)
            list
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.divider.color).frame(width: 1)
        }
    }

    private var strip: some View {
        HStack(spacing: Self.gap) {
            chips
            newShellButton
            searchField
                .frame(width: Self.stripSearchWidth)
        }
        .padding(.horizontal, Self.gap)
        .frame(height: Self.stripHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebar.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
            TextField("Search shells", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .onExitCommand { searchFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
    }

    private var newShellButton: some View {
        Button {
            workspace.newShell()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text.color)
        .help("New Shell")
        .accessibilityLabel("New Shell")
    }

    private var emptyLabel: some View {
        Text("No matching shells")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText.color)
    }

    @ViewBuilder
    private var list: some View {
        let shells = workspace.shells(matching: query)
        if shells.isEmpty {
            emptyLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.gap) {
                        ForEach(shells) { tab in
                            row(for: tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, Self.gap)
                    .padding(.bottom, 8)
                }
                .onChange(of: workspace.activeTabID) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        let shells = workspace.shells(matching: query)
        if shells.isEmpty {
            emptyLabel
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Self.gap) {
                        ForEach(shells) { tab in
                            row(for: tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .scrollPosition($stripPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    stripOffset = x
                }
                .onScrollGeometryChange(for: CGFloat.self) { max($0.contentSize.width - $0.containerSize.width, 0) } action: { _, overflow in
                    stripOverflow = overflow
                }
                .background(VerticalWheelMonitor(onScroll: scrollStrip))
                .onAppear { proxy.scrollTo(workspace.activeTabID) }
                .onChange(of: workspace.activeTabID) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func scrollStrip(by delta: CGFloat) {
        let target = min(max(stripOffset - delta, 0), stripOverflow)
        guard target != stripOffset else { return }
        stripOffset = target
        stripPosition.scrollTo(x: target)
    }

    private func chipWidth(for title: String, paneCount: Int = 1) -> CGFloat? {
        guard placement == .top else { return nil }
        var width = Self.chipChrome + Self.textWidth(title, font: Self.chipFont)
        if paneCount > 1 {
            width += 8 + Self.textWidth("\(paneCount)", font: Self.countFont)
        }
        return min(max(width, Self.chipWidthRange.lowerBound), Self.chipWidthRange.upperBound)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder
    private func row(for tab: ShellTab) -> some View {
        let height = placement == .top ? Self.chipHeight : Self.rowHeight
        if tab.isSettings {
            reorderable(
                SettingsRow(
                    height: height,
                    isSelected: workspace.activeTabID == tab.id,
                    isDropTarget: dropTargetID == tab.id,
                    select: { workspace.selectTab(tab.id) },
                    close: { workspace.closeTab(tab.id) }
                )
                .frame(width: chipWidth(for: "Settings")),
                tab: tab,
                title: "Settings"
            )
        } else if let session = workspace.representative(of: tab) {
            let title = session.customTitle ?? Block.abbreviate(session.directory)
            reorderable(
                ShellRow(
                    session: session,
                    height: height,
                    paneCount: tab.layout.leaves.count,
                    isRunning: workspace.sessions(in: tab).contains(where: \.isRunning),
                    isSelected: workspace.activeTabID == tab.id,
                    isDropTarget: dropTargetID == tab.id,
                    select: { workspace.selectTab(tab.id) },
                    close: { workspace.closeTab(tab.id) }
                )
                .frame(width: chipWidth(for: title, paneCount: tab.layout.leaves.count)),
                tab: tab,
                title: title
            )
        }
    }

    private func reorderable(_ row: some View, tab: ShellTab, title: String) -> some View {
        row
            .draggable(DraggedShell(id: tab.id)) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .dropDestination(for: DraggedShell.self) { items, _ in
                drop(items, onto: tab.id)
            } isTargeted: { targeted in
                if targeted {
                    dropTargetID = tab.id
                } else if dropTargetID == tab.id {
                    dropTargetID = nil
                }
            }
    }

    private func drop(_ items: [DraggedShell], onto id: UUID) -> Bool {
        dropTargetID = nil
        guard let item = items.first,
              item.id != id,
              let index = workspace.tabs.firstIndex(where: { $0.id == id })
        else { return false }
        workspace.moveTab(item.id, to: index)
        return true
    }
}

private nonisolated struct DraggedShell: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct ShellRow: View {
    let session: TerminalSession
    let height: CGFloat
    let paneCount: Int
    let isRunning: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var menuOpen = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            indicator
            if isRenaming {
                TextField("Shell name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text.color)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                MarqueeText(
                    text: session.customTitle ?? Block.abbreviate(session.directory),
                    isActive: isHovered,
                    trailingInset: HoverClose.coveredWidth
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.color)
            }
            if paneCount > 1, !isHovered {
                Text("\(paneCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText.color)
                    .help("\(paneCount) panes")
            }
        }
        .modifier(HoverClose(isVisible: isHovered && !isRenaming, label: "Close Shell", close: close))
        .padding(.horizontal, 8)
        .frame(height: height)
        .help(Block.abbreviate(session.directory))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.chipFill.color : (isHovered ? Theme.subtleDivider.color : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onOutsideFieldClick(isActive: isRenaming, perform: commitRename)
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(beginRename))
        .onHover { isHovered = $0 }
        .pointerMenu(isOpen: $menuOpen) {
            MenuSurface(width: 190) {
                MenuRow(title: "Rename Shell", symbol: "pencil") {
                    menuOpen = false
                    beginRename()
                }
                if session.userTitle != nil {
                    MenuRow(title: "Reset Title", symbol: "arrow.uturn.backward") {
                        menuOpen = false
                        session.rename("")
                    }
                }
                MenuDivider()
                MenuRow(title: "Close Shell", symbol: "xmark", isDestructive: true) {
                    menuOpen = false
                    close()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func beginRename() {
        draft = session.userTitle ?? ""
        isRenaming = true
        fieldFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        session.rename(draft)
    }

    @ViewBuilder
    private var indicator: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        } else if session.failure != nil {
            Circle().fill(Theme.failure.color).frame(width: 6, height: 6).frame(width: 10)
        } else {
            Circle().fill(Theme.secondaryText.color).frame(width: 6, height: 6).frame(width: 10)
        }
    }
}

private struct SettingsRow: View {
    let height: CGFloat
    let isSelected: Bool
    let isDropTarget: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 10)
            Text("Settings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(HoverClose(isVisible: isHovered, label: "Close Settings", close: close))
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.chipFill.color : (isHovered ? Theme.subtleDivider.color : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Turns vertical mouse-wheel scrolling over the view into horizontal scrolling, which a horizontal ScrollView ignores.
private struct VerticalWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
    }

    final class MonitorView: NSView {
        private static let lineScale: CGFloat = 10

        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard event.window === window,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            onScroll(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineScale)
            return true
        }
    }
}

/// Fades the trailing end of a row's content and shows a close button there, without reserving layout width for it.
private struct HoverClose: ViewModifier {
    private static let buttonWidth: CGFloat = 16
    private static let fadeWidth: CGFloat = 14
    static let coveredWidth = buttonWidth + fadeWidth

    let isVisible: Bool
    let label: String
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .mask {
                ZStack {
                    Color.black.opacity(isVisible ? 0 : 1)
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fadeWidth)
                        Color.clear.frame(width: Self.buttonWidth)
                    }
                    .opacity(isVisible ? 1 : 0)
                }
            }
            .overlay(alignment: .trailing) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: Self.buttonWidth, height: Self.buttonWidth)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText.color)
                .help(label)
                .accessibilityLabel(label)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private struct MarqueeText: View {
    let text: String
    let isActive: Bool
    var trailingInset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let speed: CGFloat = 40
    private static let fadeWidth: CGFloat = 16

    private var overflow: CGFloat {
        max(textWidth - containerWidth + (isActive ? trailingInset : 0), 0)
    }

    private var isScrolling: Bool {
        isActive && overflow > 0
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .background(WidthReader(width: $textWidth))
            .offset(x: offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WidthReader(width: $containerWidth))
            .clipped()
            .mask(fade)
            .onChange(of: isScrolling) { _, scrolling in update(scrolling) }
            .onChange(of: overflow) { update(isScrolling) }
    }

    @ViewBuilder
    private var fade: some View {
        if overflow > 0, !isActive {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
            }
        } else {
            Color.black
        }
    }

    private func update(_ scrolling: Bool) {
        if scrolling {
            let duration = Double(overflow / Self.speed)
            withAnimation(.linear(duration: duration).delay(0.4).repeatForever(autoreverses: true)) {
                offset = -overflow
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { offset = 0 }
        }
    }
}

private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        }
    }
}
