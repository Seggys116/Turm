import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var spotlightPresented: Binding<Bool>?
}

struct SpotlightView: View {
    let workspace: Workspace
    let close: (_ launched: Bool) -> Void
    @State private var query = ""
    @State private var selection = 0

    private let store = ShortcutStore.shared
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 9

    private var directory: String {
        workspace.focusedSession?.launchDirectory ?? NSHomeDirectory()
    }

    private var rows: [SpotlightRow] {
        if SpotlightModel.isSearch(query) {
            return SpotlightModel.searchRows(query: query, shells: shells)
        }
        return SpotlightModel.rows(
            query: query,
            currentDirectory: directory,
            shortcuts: store.effective(in: directory),
            history: CommandHistory.shared.entries,
            label: store.label(for:)
        )
    }

    private var shells: [SpotlightShell] {
        workspace.tabs.flatMap { tab -> [SpotlightShell] in
            if tab.isSettings {
                return [SpotlightShell(tab: tab.id, pane: nil, title: "Settings", detail: "", fields: ["Settings"], commands: [], isSettings: true)]
            }
            return tab.layout.leaves.compactMap { pane in
                guard let session = workspace.session(for: pane) else { return nil }
                var detail = session.location
                if let branch = session.git?.branch { detail += "  " + branch }
                if session.isRunning, let command = session.current?.command { detail += "  running " + command }
                return SpotlightShell(
                    tab: tab.id, pane: pane, title: session.customTitle ?? session.location, detail: detail,
                    fields: session.searchFields, commands: session.blocks.map(\.command), isSettings: false
                )
            }
        }
    }

    var body: some View {
        let visible = rows
        let current = min(selection, max(visible.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: SpotlightModel.isSearch(query) ? "magnifyingglass" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText.color)
                    .frame(width: 14)
                SpotlightField(
                    text: $query,
                    directory: directory,
                    placeholder: "Run a command, @folder, !shortcut, or ? to search shells"
                ) { key in
                    handle(key, rows: visible, current: current)
                }
                .frame(height: TerminalMetrics.lineHeight)
            }
            .padding(.horizontal, 12)
            .frame(height: SpotlightPresenter.fieldHeight)
            if !visible.isEmpty {
                Divider()
                list(rows: visible, current: current)
            } else if SpotlightModel.isSearch(query) {
                Divider()
                Text("No shells or commands match")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.color)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            }
        }
        .frame(width: SpotlightPresenter.width)
        .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.chipStroke.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
        .onChange(of: query) { selection = 0 }
    }

    private func list(rows: [SpotlightRow], current: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SpotlightRowView(row: row, isSelected: index == current)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { activate(row) }
                    }
                }
                .padding(4)
            }
            .squareScrollbar()
            .frame(height: CGFloat(min(rows.count, Self.visibleRows)) * Self.rowHeight + 8)
            .onChange(of: current) {
                if rows.indices.contains(current) { proxy.scrollTo(rows[current].id) }
            }
        }
    }

    private func handle(_ key: SpotlightKey, rows: [SpotlightRow], current: Int) {
        let row = rows.indices.contains(current) ? rows[current] : nil
        switch key {
        case .up, .down:
            guard !rows.isEmpty else { return }
            selection = (current + (key == .up ? -1 : 1) + rows.count) % rows.count
        case .tab:
            if let row, let text = SpotlightModel.completion(of: row, query: query) { query = text }
        case .submit:
            if row != nil || !SpotlightModel.isSearch(query) { activate(row) }
        case .cancel:
            close(false)
        }
    }

    private func activate(_ row: SpotlightRow?) {
        switch row?.kind {
        case .shell?, .block?:
            guard let row else { return }
            if let pane = row.pane {
                workspace.focus(pane)
            } else if let tab = row.tab {
                workspace.selectTab(tab)
            }
            if row.kind == .block, let pane = row.pane, let command = row.command {
                workspace.session(for: pane)?.search.useSelection(command)
            }
            close(true)
        default:
            workspace.newShell(directory: row?.directory, command: row?.command)
            close(true)
        }
    }
}

private struct SpotlightRowView: View {
    let row: SpotlightRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 14)
            Text(row.title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
    }
}
