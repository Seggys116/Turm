import SwiftUI

struct SpaceTitleRow: View {
    let library: SpaceLibrary
    let host: WindowHost
    @Binding var isRenaming: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var record: SpaceLibrary.Record? {
        host.spaceID.flatMap { library.record($0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            spaceIcon
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 16)
            if isRenaming {
                TextField("Space name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit(finishRename)
                    .onExitCommand { cancelRename() }
            } else {
                Text(record?.name ?? "Space")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, ChromeMetrics.trafficLightLeadingInset + ChromeMetrics.trafficLightClusterWidth + 10)
        .padding(.trailing, ChromeMetrics.sidebarHorizontalPadding)
        .frame(height: ChromeMetrics.topRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: beginRename)
        .onChange(of: isRenaming) { _, renaming in
            guard renaming else { return }
            draft = record?.name ?? draft
            focused = true
        }
        .onOutsideFieldClick(isActive: isRenaming, perform: finishRename)
        .help(record?.isTemporary == true ? "Tmp" : "Double-click to rename this space")
    }

    @ViewBuilder
    private var spaceIcon: some View {
        if let record, !record.isTemporary {
            Menu {
                SpaceIconChoices(selected: record.symbol) { library.setSymbol(record.id, to: $0) }
            } label: {
                Image(systemName: record.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change icon")
        } else {
            Image(systemName: record?.symbol ?? "terminal")
        }
    }

    private func beginRename() {
        guard let record, !record.isTemporary else { return }
        draft = record.name
        isRenaming = true
        focused = true
    }

    private func finishRename() {
        guard isRenaming, let id = host.spaceID else { return }
        isRenaming = false
        focused = false
        library.rename(id, to: draft)
    }

    private func cancelRename() {
        isRenaming = false
        focused = false
    }
}

struct SpaceSwitcher: View {
    let library: SpaceLibrary
    let host: WindowHost
    @Binding var searchPresented: Bool
    var sidebarDocked: Bool
    var beginRename: () -> Void = {}

    @State private var creating = false
    @State private var deleting: UUID?

    var body: some View {
        HStack(spacing: 2) {
            searchButton
            utilityButton("gearshape", help: "Settings") { settings?() }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(library.records) { record in
                        spaceButton(record)
                    }
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text.color)
                    .help("New Space")
                    .accessibilityLabel("New Space")
                    .popover(isPresented: $creating, arrowEdge: .bottom) {
                        NewSpacePopover(library: library, host: host) { creating = false }
                    }
                }
            }
            .scrollIndicators(.never)
            .squareScrollbar(axis: .horizontal)
            utilityButton("sidebar.left", help: sidebarDocked ? "Hide Sidebar" : "Show Sidebar") { hide?() }
        }
        .padding(.horizontal, ChromeMetrics.spotlightInset)
        .padding(.bottom, ChromeMetrics.spotlightInset)
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Space", role: .destructive) {
                if let deleting { library.delete(deleting, from: host) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Shells in this space will close.")
        }
    }

    private var deleteTitle: String {
        let name = deleting.flatMap { id in library.record(id)?.name } ?? "this space"
        return "Delete \(name)?"
    }

    private var searchButton: some View {
        Button {
            withAnimation(ChromeMetrics.motion) { searchPresented = true }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText.color)
        .opacity(searchPresented ? 0 : 1)
        .help("Search")
        .accessibilityLabel("Search")
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SearchAnchorKey.self, value: geo.frame(in: .named(TileDrag.space)))
            }
        }
    }

    var settings: (() -> Void)?
    var hide: (() -> Void)?

    private func utilityButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText.color)
        .help(help)
        .accessibilityLabel(help)
    }

    private func spaceButton(_ record: SpaceLibrary.Record) -> some View {
        let selected = record.id == host.spaceID
        return Button {
            library.activate(record.id, in: host)
        } label: {
            Image(systemName: record.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(Theme.text.color.opacity(selected ? 1 : 0.72))
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
                        .fill(selected ? Theme.chipFill.color : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(record.name)
        .accessibilityLabel(record.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if !record.isTemporary {
                Button("Rename") {
                    library.activate(record.id, in: host)
                    beginRename()
                }
                Menu("Change Icon") {
                    SpaceIconChoices(selected: record.symbol) { library.setSymbol(record.id, to: $0) }
                }
                Button("Delete Space", role: .destructive) { deleting = record.id }
                    .disabled(library.records.count < 2)
                Divider()
            }
            Button("Open in New Window") { library.openInNewWindow(record.id) }
        }
    }
}

private struct SpaceIconChoices: View {
    var selected: String
    var choose: (String) -> Void

    var body: some View {
        ForEach(SpaceIcon.palette, id: \.self) { symbol in
            Button {
                choose(symbol)
            } label: {
                Label(SpaceIcon.name(symbol), systemImage: symbol)
            }
            .disabled(symbol == selected)
        }
    }
}

private enum SpaceIcon {
    static let palette = [
        "terminal", "folder", "hammer", "leaf", "star", "book.closed",
        "cube", "globe", "laptopcomputer", "server.rack", "chevron.left.forwardslash.chevron.right",
        "shippingbox", "paintbrush", "music.note", "gamecontroller", "briefcase",
        "house", "bolt", "lightbulb", "wrench.and.screwdriver", "chart.bar", "calendar",
        "envelope", "camera", "network", "externaldrive",
    ]

    static func name(_ symbol: String) -> String {
        symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ").capitalized
    }
}

private struct NewSpacePopover: View {
    let library: SpaceLibrary
    let host: WindowHost
    var dismiss: () -> Void
    @State private var name = ""
    @State private var symbol = "terminal"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Space")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), spacing: 6) {
                ForEach(SpaceIcon.palette, id: \.self) { icon in
                    Button {
                        symbol = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(Theme.text.color)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(symbol == icon ? Theme.chipFill.color : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SpaceIcon.name(icon))
                }
            }
            HStack {
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 248)
        .onAppear { focused = true }
    }

    private func create() {
        library.create(in: host, name: name, symbol: symbol)
        dismiss()
    }
}

struct SearchAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

struct SidebarColumn<Content: View>: View {
    let library: SpaceLibrary
    let host: WindowHost
    @Binding var searchPresented: Bool
    var sidebarDocked: Bool
    var onSettings: () -> Void
    var onToggleSidebar: () -> Void
    @State private var renamingTitle = false
    @ViewBuilder var shells: () -> Content

    private func beginTitleRename() {
        guard library.record(host.spaceID ?? UUID())?.isTemporary != true else { return }
        renamingTitle = true
    }

    var body: some View {
        VStack(spacing: 0) {
            SpaceTitleRow(library: library, host: host, isRenaming: $renamingTitle)
            shells()
            SpaceSwitcher(
                library: library, host: host, searchPresented: $searchPresented, sidebarDocked: sidebarDocked,
                beginRename: beginTitleRename, settings: onSettings, hide: onToggleSidebar
            )
        }
        .background(WindowDragSurface())
    }
}
