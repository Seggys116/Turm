import SwiftUI
import UniformTypeIdentifiers

struct ShellSidebar: View {
    static let width: CGFloat = 240
    static let stripHeight: CGFloat = 36
    private static let gap: CGFloat = 6
    private static let chipWidth: CGFloat = 180
    private static let stripSearchWidth: CGFloat = 170

    let workspace: Workspace
    let placement: SidebarPlacement
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var dropTargetID: UUID?

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
        .overlay(alignment: placement == .right ? .leading : .trailing) {
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
                                .frame(width: Self.chipWidth)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo(workspace.activeTabID) }
                .onChange(of: workspace.activeTabID) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for tab: ShellTab) -> some View {
        if tab.isSettings {
            reorderable(
                SettingsRow(
                    isSelected: workspace.activeTabID == tab.id,
                    isDropTarget: dropTargetID == tab.id,
                    select: { workspace.selectTab(tab.id) },
                    close: { workspace.closeTab(tab.id) }
                ),
                tab: tab,
                title: "Settings"
            )
        } else if let session = workspace.representative(of: tab) {
            reorderable(
                ShellRow(
                    session: session,
                    paneCount: tab.layout.leaves.count,
                    isRunning: workspace.sessions(in: tab).contains(where: \.isRunning),
                    isSelected: workspace.activeTabID == tab.id,
                    isDropTarget: dropTargetID == tab.id,
                    select: { workspace.selectTab(tab.id) },
                    close: { workspace.closeTab(tab.id) }
                ),
                tab: tab,
                title: session.customTitle ?? Block.abbreviate(session.directory)
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
                    isActive: isHovered
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.color)
            }
            Spacer(minLength: 0)
            if paneCount > 1, !isHovered {
                Text("\(paneCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText.color)
                    .help("\(paneCount) panes")
            }
            if isHovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText.color)
                .help("Close Shell")
                .accessibilityLabel("Close Shell")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
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
            Spacer(minLength: 0)
            if isHovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText.color)
                .help("Close Settings")
                .accessibilityLabel("Close Settings")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
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

private struct MarqueeText: View {
    let text: String
    let isActive: Bool
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let speed: CGFloat = 40
    private static let fadeWidth: CGFloat = 16

    private var overflow: CGFloat {
        max(textWidth - containerWidth, 0)
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
