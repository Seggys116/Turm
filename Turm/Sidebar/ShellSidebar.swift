import AppKit
import SwiftUI
import TurmCore

struct ShellSidebar: View {
    static let width: CGFloat = 196
    static let stripHeight: CGFloat = 32
    private static let gap: CGFloat = 4
    static let corner: CGFloat = 2
    private static let rowHeight: CGFloat = 26
    private static let chipHeight: CGFloat = 24
    private static let chipWidthRange: ClosedRange<CGFloat> = 72...200
    /// Row padding, indicator and the spacing after it.
    private static let chipChrome: CGFloat = 34
    private static let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let countFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let stripSearchWidth: CGFloat = 150
    private static let space = "shellTabs"
    private static let slide = Animation.spring(duration: 0.24, bounce: 0.1)

    let workspace: Workspace
    let placement: SidebarPlacement
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var drag: TabDrag?
    @State private var rowFrames: [UUID: CGRect] = [:]
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
        .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: ShellSidebar.corner))
        .overlay(RoundedRectangle(cornerRadius: ShellSidebar.corner).stroke(Theme.chipStroke.color, lineWidth: 1))
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
                    reorderable(shells)
                        .padding(.horizontal, Self.gap)
                    .padding(.bottom, 8)
                }
                .squareScrollbar()
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
                    reorderable(shells)
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

    private func chipWidth(for title: String, paneCount: Int = 1, activity: ShellActivity = .inactive) -> CGFloat? {
        guard placement == .top else { return nil }
        var width = Self.chipChrome + Self.textWidth(title, font: Self.chipFont)
        if paneCount > 1 {
            width += 8 + Self.textWidth("\(paneCount)", font: Self.countFont)
        }
        if case .progress = activity {
            width += 8 + Self.textWidth("100%", font: Self.countFont)
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
            SettingsRow(
                height: height,
                isSelected: workspace.activeTabID == tab.id,
                select: { workspace.selectTab(tab.id) },
                close: { workspace.closeTab(tab.id) }
            )
            .frame(width: chipWidth(for: "Settings"))
        } else if let session = workspace.representative(of: tab) {
            let title = session.customTitle ?? session.location
            let sessions = workspace.sessions(in: tab)
            let activity = ShellActivity.combined(sessions.map(\.activity))
            ShellRow(
                session: session,
                height: height,
                paneCount: tab.layout.leaves.count,
                activity: activity,
                program: (sessions.first(where: { $0.activity.isBusy }) ?? session).displayedProgram,
                actionActivity: ShellActivity.combined(sessions.map(\.runner.activity)),
                isSelected: workspace.activeTabID == tab.id,
                acknowledge: { sessions.forEach { $0.acknowledgeOutcome() } },
                select: { workspace.selectTab(tab.id) },
                close: { workspace.closeTab(tab.id) }
            )
            .frame(width: chipWidth(for: title, paneCount: tab.layout.leaves.count, activity: activity))
        }
    }

    private var isHorizontal: Bool { placement == .top }

    private func mainAxis(_ point: CGPoint) -> CGFloat { isHorizontal ? point.x : point.y }
    private func mainOrigin(_ frame: CGRect) -> CGFloat { isHorizontal ? frame.minX : frame.minY }
    private func mainLength(_ frame: CGRect) -> CGFloat { isHorizontal ? frame.width : frame.height }

    /// The shells as they would sit if the drag ended now, so the rest slide aside for the one being held.
    private func arranged(_ shells: [ShellTab]) -> [ShellTab] {
        guard let drag, let held = shells.first(where: { $0.id == drag.id }), let frame = rowFrames[drag.id] else { return shells }
        var rest = shells.filter { $0.id != drag.id }
        let center = drag.pointer - drag.grab + mainLength(frame) / 2
        var index = 0
        for tab in rest {
            guard let other = rowFrames[tab.id], (isHorizontal ? other.midX : other.midY) < center else { break }
            index += 1
        }
        rest.insert(held, at: index)
        return rest
    }

    private func reorderable(_ shells: [ShellTab]) -> some View {
        let order = arranged(shells)
        let layout = isHorizontal
            ? AnyLayout(HStackLayout(spacing: Self.gap))
            : AnyLayout(VStackLayout(spacing: Self.gap))
        return layout {
            ForEach(order) { tab in
                row(for: tab)
                    .geometryGroup()
                    .opacity(drag?.id == tab.id ? 0 : 1)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFrames.self, value: [tab.id: proxy.frame(in: .named(Self.space))])
                    })
                    .simultaneousGesture(dragGesture(for: tab))
                    .id(tab.id)
            }
        }
        .animation(Self.slide, value: order.map(\.id))
        .overlay(alignment: .topLeading) {
            floating(order).transaction { $0.animation = nil }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
    }

    @ViewBuilder
    private func floating(_ order: [ShellTab]) -> some View {
        if let drag, let tab = order.first(where: { $0.id == drag.id }), let frame = rowFrames[drag.id] {
            let lower = rowFrames.values.map(mainOrigin).min() ?? 0
            let upper = (rowFrames.values.map { mainOrigin($0) + mainLength($0) }.max() ?? 0) - mainLength(frame)
            let position = min(max(drag.pointer - drag.grab, lower), max(upper, lower))
            row(for: tab)
                .geometryGroup()
                .frame(width: frame.width, height: frame.height)
                .background(Theme.sidebar.color, in: RoundedRectangle(cornerRadius: ShellSidebar.corner))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .offset(x: isHorizontal ? position : frame.minX, y: isHorizontal ? frame.minY : position)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(for tab: ShellTab) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard let frame = rowFrames[tab.id] else { return }
                    drag = TabDrag(id: tab.id, pointer: mainAxis(value.location), grab: mainAxis(value.startLocation) - mainOrigin(frame))
                }
                guard drag?.id == tab.id else { return }
                drag?.pointer = mainAxis(value.location)
            }
            .onEnded { _ in finishDrag() }
    }

    private func finishDrag() {
        guard let held = drag?.id else { return }
        let order = arranged(workspace.shells(matching: query)).map(\.id)
        let others = workspace.tabs.map(\.id).filter { $0 != held }
        var target = others.count
        if let position = order.firstIndex(of: held) {
            if order.indices.contains(position + 1), let next = others.firstIndex(of: order[position + 1]) {
                target = next
            } else if position > 0, let previous = others.firstIndex(of: order[position - 1]) {
                target = previous + 1
            }
        }
        withAnimation(Self.slide) {
            workspace.moveTab(held, to: target)
            drag = nil
        }
    }
}

private struct TabDrag {
    var id: UUID
    var pointer: CGFloat
    var grab: CGFloat
}

private struct RowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ShellRow: View {
    let session: TerminalSession
    let height: CGFloat
    let paneCount: Int
    let activity: ShellActivity
    let program: RunningProgram?
    let actionActivity: ShellActivity
    let isSelected: Bool
    let acknowledge: () -> Void
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var pulse: OutcomePulse?
    @State private var actionPulse: OutcomePulse?
    @State private var menuOpen = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ActivityIndicator(activity: activity, pulse: pulse, program: program, action: actionActivity, actionPulse: actionPulse)
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
                    text: session.customTitle ?? session.location,
                    isActive: isHovered,
                    trailingInset: HoverClose.coveredWidth
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.color)
            }
            if case .progress(let value) = activity, !isHovered {
                Text(ActivityIndicator.percentText(value))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText.color)
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
        .help((program.map { $0.name + " - " } ?? "") + (session.remote.map { $0.host + ":" + session.directory } ?? Block.abbreviate(session.directory)))
        .background(
            RoundedRectangle(cornerRadius: ShellSidebar.corner)
                .fill(isSelected ? Theme.chipFill.color : (isHovered ? Theme.subtleDivider.color : .clear))
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
        .onAppear(perform: settleOutcome)
        .onChange(of: isSelected) { settleOutcome() }
        .onChange(of: activity) { settleOutcome() }
        .onChange(of: actionActivity) { settleOutcome() }
    }

    /// A result stays lit only on shells out of view; the one in view flashes it and returns to idle.
    private func settleOutcome() {
        guard isSelected else { return }
        let now = Date()
        let shell = OutcomePulse(activity, at: now)
        let action = OutcomePulse(actionActivity, at: now)
        guard shell != nil || action != nil else { return }
        if let shell { pulse = shell }
        if let action { actionPulse = action }
        acknowledge()
        Task {
            try? await Task.sleep(for: .seconds(OutcomePulse.duration))
            if pulse?.start == now { pulse = nil }
            if actionPulse?.start == now { actionPulse = nil }
        }
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
}

private struct OutcomePulse: Equatable {
    static let duration: TimeInterval = 1.6

    let failed: Bool
    let start: Date

    init?(_ activity: ShellActivity, at start: Date) {
        switch activity {
        case .succeeded: failed = false
        case .failed: failed = true
        default: return nil
        }
        self.start = start
    }
}

private struct ActivityIndicator: View {
    let activity: ShellActivity
    let pulse: OutcomePulse?
    var program: RunningProgram?
    var action: ShellActivity = .inactive
    var actionPulse: OutcomePulse?

    // Room for the outcome ring, which grows past the glyph and would be cut off by the compositing group.
    private static let bleed: CGFloat = 5

    static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded(.down)))%"
    }

    private var showsAction: Bool {
        action != .inactive || actionPulse != nil
    }

    var body: some View {
        ZStack {
            StatusGlyph(activity: activity, pulse: pulse, diameter: 10, program: program)
            if showsAction {
                Circle()
                    .frame(width: 8, height: 8)
                    .offset(x: 4, y: 4)
                    .blendMode(.destinationOut)
            }
        }
        .padding(Self.bleed)
        .compositingGroup()
        .padding(-Self.bleed)
        .overlay {
            if showsAction {
                StatusGlyph(activity: action, pulse: actionPulse, diameter: 5)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        let shell = switch activity {
        case .working: program.map { "\($0.name), running" } ?? "Running"
        case .progress(let value): "\(program.map { "\($0.name), running" } ?? "Running"), \(Self.percentText(value))"
        case .succeeded: program.map { "\($0.name), last command succeeded" } ?? "Last command succeeded"
        case .failed: program.map { "\($0.name), last command failed" } ?? "Last command failed"
        case .inactive: "Idle"
        }
        let bar: String? = switch action {
        case .working: "project action running"
        case .progress(let value): "project action at \(Self.percentText(value))"
        case .succeeded: "project action succeeded"
        case .failed: "project action failed"
        case .inactive: nil
        }
        return bar.map { "\(shell), \($0)" } ?? shell
    }
}

private struct StatusGlyph: View {
    let activity: ShellActivity
    let pulse: OutcomePulse?
    let diameter: CGFloat
    var program: RunningProgram?

    private var dotSize: CGFloat { diameter * 0.6 }
    private var lineWidth: CGFloat { max(diameter / 5, 1.25) }

    var body: some View {
        Group {
            if let pulse, !activity.isBusy {
                pulsing(pulse)
            } else {
                state
            }
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var state: some View {
        switch activity {
        case .working:
            if let program, diameter >= 10 {
                programGlyph(program)
            } else if diameter >= 10 {
                ProgressView().controlSize(.mini)
            } else {
                spinner
            }
        case .progress(let value):
            if let program, usesGlyph {
                programGlyph(program)
            } else {
                ZStack {
                    Circle()
                        .stroke(Theme.subtleDivider.color, lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: value / 100)
                        .stroke(Theme.added.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: value)
                }
                .padding(lineWidth / 2)
            }
        case .succeeded:
            marker(Theme.added.color)
        case .failed:
            marker(Theme.failure.color)
        case .inactive:
            dot(Theme.secondaryText.color)
        }
    }

    private var usesGlyph: Bool { program != nil && diameter >= 10 }

    private func programImage(_ program: RunningProgram, tint: SwiftUI.Color) -> some View {
        ProgramGlyph(program, size: diameter).foregroundStyle(tint)
    }

    private func programGlyph(_ program: RunningProgram) -> some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            programImage(program, tint: Theme.text.color)
                .opacity(0.65 + 0.35 * (0.5 + 0.5 * sin(phase * 2 * .pi)))
        }
    }

    @ViewBuilder
    private func marker(_ color: SwiftUI.Color) -> some View {
        if usesGlyph, let program {
            programImage(program, tint: color)
        } else {
            dot(color)
        }
    }

    private var spinner: some View {
        TimelineView(.animation) { timeline in
            let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.secondaryText.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(lineWidth / 2)
        }
    }

    private func pulsing(_ pulse: OutcomePulse) -> some View {
        let color = pulse.failed ? Theme.failure.color : Theme.added.color
        return TimelineView(.animation) { timeline in
            let progress = min(max(timeline.date.timeIntervalSince(pulse.start) / OutcomePulse.duration, 0), 1)
            let wave = (progress * 2).truncatingRemainder(dividingBy: 1)
            if usesGlyph, let program {
                let handoff = max(progress - 0.75, 0) / 0.25
                ZStack {
                    dot(Theme.secondaryText.color).opacity(handoff)
                    programImage(program, tint: color)
                        .opacity((1 - handoff) * (0.65 + 0.35 * (0.5 + 0.5 * cos(wave * 2 * .pi))))
                }
            } else {
                ZStack {
                    dot(Theme.secondaryText.color)
                    dot(color).opacity(progress < 0.5 ? 1 : 1 - (progress - 0.5) * 2)
                    if progress < 1 {
                        Circle()
                            .stroke(color, lineWidth: max(lineWidth * 0.75, 1))
                            .frame(width: dotSize, height: dotSize)
                            .scaleEffect(1 + 1.4 * wave)
                            .opacity((1 - wave) * 0.85)
                    }
                }
            }
        }
    }

    private func dot(_ color: SwiftUI.Color) -> some View {
        Circle().fill(color).frame(width: dotSize, height: dotSize)
    }
}

private struct SettingsRow: View {
    let height: CGFloat
    let isSelected: Bool
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
            RoundedRectangle(cornerRadius: ShellSidebar.corner)
                .fill(isSelected ? Theme.chipFill.color : (isHovered ? Theme.subtleDivider.color : .clear))
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
    // How far the mask reaches past the leading and vertical edges, so the status pulse is not cut off.
    private static let overhang: CGFloat = 8

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
                .padding(EdgeInsets(top: -Self.overhang, leading: -Self.overhang, bottom: -Self.overhang, trailing: 0))
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
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
