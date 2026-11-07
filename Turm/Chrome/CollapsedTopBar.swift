import SwiftUI
import TurmCore

/// The row shown above the content while the sidebar is collapsed.
struct CollapsedTopBar: View {
    let library: SpaceLibrary
    let host: WindowHost
    let workspace: Workspace
    var onDock: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            DockButton(action: onDock)
            spaceLabel
            let row = chipRow
            ViewThatFits(in: .horizontal) {
                row.frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NewShellButton { workspace.newShell() }
        }
        .padding(.leading, ChromeMetrics.trafficLightLeadingInset + ChromeMetrics.trafficLightClusterWidth + 8)
        .padding(.trailing, ChromeMetrics.cardInset)
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.topRowHeight)
        .background(WindowDragSurface())
    }

    private var spaceLabel: some View {
        SpaceMenu(library: library, host: host)
    }

    private var chipRow: some View {
        HStack(spacing: 4) {
            ForEach(workspace.tabs) { tab in
                ShellChip(
                    title: workspace.title(of: tab),
                    isSettings: tab.isSettings,
                    activity: ShellActivity.combined(workspace.sessions(in: tab).map(\.activity)),
                    program: workspace.sessions(in: tab).first(where: { $0.activity.isBusy })?.displayedProgram,
                    isSelected: workspace.activeTabID == tab.id,
                    select: { workspace.selectTab(tab.id) },
                    close: { workspace.closeTab(tab.id) }
                )
                .id(tab.id)
            }
        }
    }
}

private struct DockButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
                    .fill(hovering ? Theme.chipFill.color : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show Sidebar")
        .accessibilityLabel("Show Sidebar")
    }
}

private struct ShellChip: View {
    var title: String
    var isSettings: Bool
    var activity: ShellActivity
    var program: RunningProgram?
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                if isSettings {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                } else {
                    StatusGlyph(activity: activity, pulse: nil, diameter: 12, program: program)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                closeSlot
            }
            .foregroundStyle(Theme.text.color.opacity(isSelected ? 1 : 0.8))
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(shape.fill(isSelected ? Theme.chipFill.color : (hovering ? Theme.subtleDivider.color : Color.clear)))
            .overlay(shape.strokeBorder(isSelected ? Theme.chipStroke.color : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var closeSlot: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.secondaryText.color)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Theme.chipFill.color).opacity(hovering ? 1 : 0))
            .opacity(hovering ? 1 : 0)
            .contentShape(Circle())
            .onTapGesture(perform: close)
            .accessibilityHidden(true)
    }
}

private struct NewShellButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.color)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
                    .fill(hovering ? Theme.chipFill.color : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Shell")
        .accessibilityLabel("New Shell")
    }
}

extension Workspace {
    /// The name a shell goes by in the sidebar and in the top bar.
    func title(of tab: ShellTab) -> String {
        if tab.isSettings { return "Settings" }
        guard let representative = representative(of: tab) else { return "Shell" }
        guard tab.layout.leaves.count > 1 else { return representative.customTitle ?? representative.location }
        if let title = tab.title { return title }
        return sessions(in: tab).map { $0.customTitle ?? $0.location }.joined(separator: " · ")
    }
}

private struct SpaceMenu: View {
    let library: SpaceLibrary
    let host: WindowHost
    @State private var creating = false
    @State private var hovering = false

    private var record: SpaceLibrary.Record? {
        host.spaceID.flatMap { library.record($0) }
    }

    var body: some View {
        Menu {
            ForEach(library.records) { space in
                Button {
                    library.activate(space.id, in: host)
                } label: {
                    Label(space.name, systemImage: space.id == host.spaceID ? "checkmark" : space.symbol)
                }
            }
            Divider()
            Button("New Space...") { creating = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: record?.symbol ?? "terminal")
                    .font(.system(size: 12, weight: .medium))
                Text(record?.name ?? "Space")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText.color)
            }
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
                .fill(hovering ? Theme.chipFill.color : Color.clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Switch Space")
        .accessibilityLabel("Switch Space")
        .popover(isPresented: $creating, arrowEdge: .bottom) {
            NewSpacePopover(library: library, host: host) { creating = false }
        }
    }
}
