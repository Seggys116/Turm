import AppKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

private enum BarMenu: Hashable {
    case tool
    case variant(String)
    case all
}

private struct SettlingSchedule: TimelineSchedule {
    let end: Date?

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard let end, end > start else { return AnySequence([end.map { max($0, start) } ?? start]) }
        let step = 1.0 / 24
        let count = Int(end.timeIntervalSince(start) / step)
        let ticks = (0...count).lazy.map { start.addingTimeInterval(Double($0) * step) }
        return AnySequence(Array(ticks) + [end])
    }
}

private struct OverflowLayout: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: proposal.width.map { min(total, $0) } ?? total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var overflowed = false
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !overflowed, x + size.width <= bounds.maxX + 0.5 {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            } else {
                overflowed = true
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}

struct StatusBar: View {
    let session: TerminalSession
    let bar: ResolvedBar
    @State private var open: BarMenu?

    private var runner: ActionRunner { session.runner }
    private var display: ResolvedBar.Display { bar.display(choice: session.toolChoice) }

    private var canRun: Bool {
        bar.subShell ? !runner.isRunning : session.phase == .ready
    }

    private var contentAlignment: Alignment {
        switch bar.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let active = display.active {
                BarChip(symbol: active.symbol, title: active.title, isActive: open == .tool) { toggle(.tool) }
                    .fixedSize()
                    .anchoredMenu(isOpen: binding(.tool)) {
                        ToolMenu(session: session, tools: display.selector, active: active.id) { open = nil }
                    }
            }
            content
                .frame(maxWidth: .infinity, alignment: contentAlignment)
                .clipped()
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(progressBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch bar.titles {
        case .always: row(titles: true)
        case .never: row(titles: false)
        case .auto:
            ViewThatFits(in: .horizontal) {
                row(titles: true)
                row(titles: false)
            }
        }
    }

    private func row(titles: Bool) -> some View {
        OverflowLayout {
            ForEach(display.entries) { item in
                switch item {
                case .action(let action):
                    BarButton(
                        symbol: bar.symbol(for: action),
                        title: titles ? action.title : nil,
                        isEnabled: canRun,
                        help: session.project.commandLine(for: action, selection: session.variantChoices, from: session.directory)
                    ) { session.run(action) }
                case .variant(let variant):
                    let menu = BarMenu.variant(variant.id)
                    BarChip(title: variant.option(at: session.variantChoices[variant.id]).label, isActive: open == menu, isQuiet: true) { toggle(menu) }
                        .help(variant.title)
                        .anchoredMenu(isOpen: binding(menu)) {
                            OptionMenu(session: session, variant: variant) { open = nil }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let notice = session.project.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.removed.color)
                .lineLimit(1)
                .help(notice)
        }
        if bar.subShell {
            subShellControls
        } else if session.isRunning {
            if let command = session.current?.command { runningText(command) }
            BarButton(symbol: "stop.fill", title: "Stop", tint: Theme.removed.color, isEnabled: true, help: "Interrupt the running command") {
                session.interrupt()
            }
        }
        BarButton(symbol: "ellipsis", title: nil, isActive: open == .all, isEnabled: true, help: "All project actions") {
            toggle(.all)
        }
        .anchoredMenu(isOpen: binding(.all)) {
            AllActionsMenu(session: session, bar: bar) { open = nil }
        }
    }

    @ViewBuilder
    private var subShellControls: some View {
        if runner.isActive {
            if runner.isRunning { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
            if let command = runner.command { runningText(command) }
            if let code = runner.exitCode, runner.progress?.outcome == .failed {
                Text("exit \(code)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.removed.color)
            }
            BarButton(
                symbol: runner.isInteractive ? "hand.point.up.left.fill" : "eye",
                title: runner.isInteractive ? "Interact" : "Watch",
                isActive: runner.isWatching,
                isEnabled: true,
                help: "Show the output of this action"
            ) { runner.isWatching.toggle() }
            if runner.isRunning {
                BarButton(symbol: "stop.fill", title: "Stop", tint: Theme.removed.color, isEnabled: true, help: "Interrupt the action") {
                    runner.stop()
                }
            } else {
                BarButton(symbol: "xmark", title: nil, isEnabled: true, help: "Dismiss the result") {
                    runner.dismiss()
                }
            }
        }
    }

    private func runningText(_ command: String) -> some View {
        Text(command)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 200)
            .layoutPriority(-1)
    }

    @ViewBuilder
    private var progressBackground: some View {
        ZStack {
            Theme.statusBar.color
            if let progress = runner.progress, bar.subShell {
                switch progress.outcome {
                case .running:
                    if let report = runner.session?.progress { ReportedFill(report: report) }
                case .succeeded:
                    let end = progress.finishedAt?.addingTimeInterval(ActionProgress.successHold + ActionProgress.fade + 0.01)
                    TimelineView(SettlingSchedule(end: end)) { context in
                        if progress.isSettled(at: context.date) {
                            SwiftUI.Color.clear
                        } else {
                            Theme.added.color.opacity(0.28 * progress.successOpacity(at: context.date))
                        }
                    }
                case .failed:
                    let end = progress.finishedAt?.addingTimeInterval(ActionProgress.pulseDuration + 0.01)
                    TimelineView(SettlingSchedule(end: end)) { context in
                        Theme.removed.color.opacity(0.08 + 0.3 * progress.pulse(at: context.date))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func toggle(_ menu: BarMenu) {
        open = open == menu ? nil : menu
    }

    private func binding(_ menu: BarMenu) -> Binding<Bool> {
        Binding(
            get: { open == menu },
            set: { isOpen in
                if isOpen { open = menu } else if open == menu { open = nil }
            }
        )
    }
}

struct BarButton: View {
    let symbol: String
    var title: String?
    var tint: SwiftUI.Color?
    var isActive = false
    let isEnabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                if let title {
                    Text(title).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(tint ?? Theme.text.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isActive ? 0.22 : hovering && isEnabled ? 0.16 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct BarChip: View {
    var symbol: String?
    let title: String
    var isActive = false
    var isQuiet = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 12)
                }
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.secondaryText.color)
            }
            .font(.system(size: isQuiet ? 10 : 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(isActive ? 0.22 : hovering ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isActive || hovering ? Color.accentColor.opacity(0.7) : Theme.chipStroke.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

private enum MiniMenu {
    static let rowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 18
    static let maxHeight: CGFloat = 264

    static func width(for titles: [String], extra: CGFloat = 0) -> CGFloat {
        let longest = titles.map(\.count).max() ?? 0
        return min(max(CGFloat(longest) * 6.7 + 46 + extra, 120), 280)
    }

    static func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.secondaryText.color)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .frame(height: headerHeight, alignment: .bottomLeading)
    }
}

private struct ToolMenu: View {
    let session: TerminalSession
    let tools: [ResolvedBar.Group]
    let active: String
    let close: () -> Void

    var body: some View {
        MenuSurface(width: MiniMenu.width(for: tools.map(\.title))) {
            ForEach(tools) { tool in
                MenuRow(title: tool.title, symbol: tool.symbol, isCurrent: tool.id == active, compact: true) {
                    session.chooseTool(tool.id)
                    close()
                }
            }
        }
    }
}

private struct OptionMenu: View {
    let session: TerminalSession
    let variant: ProjectVariant
    let close: () -> Void

    var body: some View {
        let current = variant.option(at: session.variantChoices[variant.id])
        MenuSurface(width: MiniMenu.width(for: variant.options.map(\.label))) {
            MiniMenu.header(variant.title)
            ForEach(Array(variant.options.enumerated()), id: \.offset) { index, option in
                MenuRow(title: option.label, isCurrent: option == current, compact: true) {
                    session.choose(variant, index: index)
                    close()
                }
            }
        }
    }
}

private struct AllActionsMenu: View {
    let session: TerminalSession
    let bar: ResolvedBar
    let close: () -> Void

    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 24
    private static let maxHeight: CGFloat = 360

    private var sections: [(title: String, actions: [ProjectAction])] {
        if bar.groups.count > 1 {
            return bar.groups.map { group in
                (group.title, ActionCategory.allCases.flatMap { category in group.actions.filter { $0.category == category } })
            }
        }
        let actions = bar.groups.first?.actions ?? []
        return ActionCategory.allCases.compactMap { category in
            let members = actions.filter { $0.category == category }
            return members.isEmpty ? nil : (category.title, members)
        }
    }

    var body: some View {
        let variants = bar.groups.flatMap(\.variants)
        let sections = sections
        let rows = sections.reduce(0) { $0 + $1.actions.count } + variants.count + 1
        let headers = sections.count + (variants.isEmpty ? 0 : 1)
        let height = CGFloat(rows) * Self.rowHeight + CGFloat(headers) * Self.headerHeight
        MenuSurface(width: 300) {
            if let notice = session.project.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.removed.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MenuDivider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !variants.isEmpty {
                        header("Options")
                        ForEach(variants) { variant in
                            MenuRow(
                                title: variant.title,
                                symbol: "arrow.triangle.2.circlepath",
                                detail: variant.option(at: session.variantChoices[variant.id]).label
                            ) { session.cycle(variant) }
                        }
                    }
                    ForEach(sections, id: \.title) { section in
                        header(section.title)
                        ForEach(section.actions) { action in
                            MenuRow(title: action.title, symbol: bar.symbol(for: action)) {
                                session.run(action)
                                close()
                            }
                            .disabled(bar.subShell ? session.runner.isRunning : session.phase != .ready)
                        }
                    }
                    manifestRow
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(height, Self.maxHeight))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.secondaryText.color)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    @ViewBuilder
    private var manifestRow: some View {
        if let path = session.project.manifestPath {
            MenuRow(title: "Edit Turm.json", symbol: "doc.badge.gearshape") {
                Self.openInTextEditor(URL(fileURLWithPath: path))
                close()
            }
        } else {
            MenuRow(title: "Create Turm.json", symbol: "doc.badge.plus") {
                createManifest()
                close()
            }
        }
    }

    private static func openInTextEditor(_ url: URL) {
        let workspace = NSWorkspace.shared
        let editor = workspace.urlForApplication(toOpen: .plainText) ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    private func createManifest() {
        let root = session.project.roots.first ?? session.directory
        let url = URL(fileURLWithPath: root).appendingPathComponent(ProjectManifest.fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try ProjectManifest.template.write(to: url, atomically: true, encoding: .utf8)
            Self.openInTextEditor(url)
        } catch {
            NSSound.beep()
        }
    }
}

private struct ReportedFill: View {
    let report: Terminal.ProgressReport

    var body: some View {
        GeometryReader { proxy in
            if report.state == .indeterminate {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Rectangle()
                        .fill(color.opacity(0.28))
                        .frame(width: proxy.size.width * 0.2)
                        .offset(x: proxy.size.width * 1.2 * phase - proxy.size.width * 0.2)
                }
            } else {
                Rectangle()
                    .fill(color.opacity(0.3))
                    .frame(width: proxy.size.width * Double(report.progress ?? 0) / 100)
                    .animation(.easeOut(duration: 0.2), value: report.progress)
            }
        }
        .clipped()
    }

    private var color: SwiftUI.Color {
        switch report.state {
        case .error: Theme.removed.color
        case .pause: Theme.secondaryText.color
        default: Theme.added.color
        }
    }
}
