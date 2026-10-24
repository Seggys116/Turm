import SwiftUI
import TurmCore

struct MacSpaceGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var sessions: [SessionSummary]
}

enum MacSpaces {
    static func groups(in sessions: [SessionSummary]) -> [MacSpaceGroup] {
        let buckets = Dictionary(grouping: sessions) { session in
            session.spaceID?.uuidString ?? session.spaceName ?? session.windowTitle ?? "Mac"
        }
        return buckets.map { key, list in
            MacSpaceGroup(
                id: key,
                name: list.first?.spaceName ?? list.first?.windowTitle ?? "Space",
                symbol: list.first?.spaceSymbol ?? "terminal",
                sessions: list
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == SavedSpace.temporaryName { return true }
            if rhs.name == SavedSpace.temporaryName { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct MacSpacesPage: View {
    let workspace: Workspace
    let macs: MacManager
    let connection: MacConnection
    let entry: MacEntry
    @Binding var path: [HomeRoute]
    @State private var forgetting = false

    var body: some View {
        List {
            Section {
                MacRow(mac: entry)
                    .chromeListRow()
            } footer: {
                if let advice = connection.updateAdvice {
                    Text(advice)
                } else if let notice = connection.notice {
                    Text(notice)
                }
            }
            switch connection.state {
            case .connected:
                Section("Spaces") {
                    let groups = MacSpaces.groups(in: connection.sessions)
                    if groups.isEmpty {
                        Text("No shells are open on this Mac.")
                            .foregroundStyle(Chrome.secondaryText)
                            .chromeListRow()
                    }
                    ForEach(groups) { group in
                        Button {
                            path.append(.space(mac: entry.id, space: group.id))
                        } label: {
                            HStack(spacing: 8) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name)
                                            .foregroundStyle(Chrome.text)
                                        Text(group.sessions.count == 1 ? "1 shell" : "\(group.sessions.count) shells")
                                            .font(.caption)
                                            .foregroundStyle(Chrome.secondaryText)
                                    }
                                } icon: {
                                    Image(systemName: group.symbol)
                                        .foregroundStyle(Chrome.secondaryText)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .chromeListRow()
                    }
                }
            case .failed:
                Section {
                    Button("Try Again", systemImage: "arrow.clockwise") { connection.start() }
                        .buttonStyle(.plain)
                        .chromeListRow()
                }
            case .offline, .connecting, .retrying:
                Section {
                    Text(entry.detail)
                        .foregroundStyle(Chrome.secondaryText)
                        .chromeListRow()
                }
            }
            Section {
                Button("Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Chrome.failure)
                    .chromeListRow()
            }
        }
        .chromeList()
        .navigationTitle(connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { connection.refreshSessions() }
        .chromeDialog(isPresented: $forgetting) {
            .confirmation(
                title: "Forget \(connection.name)?",
                message: "This device loses access to the Mac. Pair again to reconnect.",
                confirm: "Forget"
            ) { macs.forget(connection.id) }
        }
    }
}

struct MacSpaceShells: View {
    let workspace: Workspace
    let connection: MacConnection
    let group: MacSpaceGroup
    @State private var query = ""
    @State private var draft = ""
    @State private var composing = false
    @State private var closing: UUID?
    @FocusState private var draftFocused: Bool
    @Environment(\.chromeOverlays) private var overlays
    @State private var closeToken = UUID()

    private var shells: [SessionSummary] {
        let all = connection.sessions.filter { session in
            let key = session.spaceID?.uuidString ?? session.spaceName ?? session.windowTitle ?? "Mac"
            return key == group.id
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedStandardContains(needle)
                || $0.location.localizedStandardContains(needle)
                || ($0.directory?.localizedStandardContains(needle) ?? false)
        }
    }

    var body: some View {
        List {
            if shells.isEmpty {
                Text(query.isEmpty ? "Nothing is open in this space." : "No shells match.")
                    .foregroundStyle(Chrome.secondaryText)
                    .chromeListRow()
            }
            ForEach(shells) { summary in
                Button {
                    workspace.open(connection.session(for: summary.id))
                } label: {
                    MacSessionRow(summary: summary)
                }
                .buttonStyle(.plain)
                .chromeListRow(selected: workspace.selectedID == summary.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Close", role: .destructive) {
                        closing = summary.id
                    }
                    .tint(Chrome.failure)
                }
            }
        }
        .chromeList()
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SpaceShellBar(query: $query, draft: $draft, composing: $composing, focused: $draftFocused, create: createShell))
        .onChange(of: closing) { _, id in
            guard let id else { return }
            askToClose(id)
        }
        .confirmationDialog(
            "Close this shell?",
            isPresented: Binding(get: { closing != nil && overlays == nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                if let closing { connection.closeSession(closing, force: true) }
                closing = nil
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: {
            Text("This shell will close.")
        }
    }

    private func askToClose(_ id: UUID) {
        guard let overlays else { return }
        overlays.present(
            dialog: ChromeDialogSpec(
                title: "Close this shell?",
                message: "This shell will close.",
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Close", role: .destructive) { _ in
                        connection.closeSession(id, force: true)
                    },
                ]
            ),
            token: closeToken
        ) {
            closing = nil
        }
    }

    private var spaceID: UUID? {
        connection.sessions.first { session in
            (session.spaceID?.uuidString ?? session.spaceName ?? session.windowTitle ?? "Mac") == group.id
        }?.spaceID ?? UUID(uuidString: group.id)
    }

    private func createShell() {
        let folder = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        composing = false
        connection.createShell(directory: folder.isEmpty ? nil : folder, space: spaceID) { id in
            workspace.open(connection.session(for: id))
        }
    }
}

private struct SpaceShellBar: ViewModifier {
    @Binding var query: String
    @Binding var draft: String
    @Binding var composing: Bool
    var focused: FocusState<Bool>.Binding
    var create: () -> Void

    func body(content: Content) -> some View {
        if composing {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) {
                    TextField("New shell", text: $draft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .focused(focused)
                        .submitLabel(.go)
                        .onSubmit(create)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Cancel", systemImage: "xmark") {
                        draft = ""
                        composing = false
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .onAppear { focused.wrappedValue = true }
        } else if #available(iOS 26, *) {
            content
                .searchable(text: $query, prompt: "Search shells")
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("New Shell", systemImage: "plus") { composing = true }
                            .labelStyle(.iconOnly)
                    }
                }
        } else {
            content
                .searchable(text: $query, prompt: "Search shells")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button("New Shell", systemImage: "plus") { composing = true }
                            .labelStyle(.iconOnly)
                    }
                }
        }
    }
}

struct MacGroup: View {
    let workspace: Workspace
    let macs: MacManager
    let connection: MacConnection
    let entry: MacEntry
    @State private var expanded = true
    @State private var creating = false
    @State private var forgetting = false

    private var closeAlert: Binding<Bool> {
        Binding(get: { connection.closeRequest != nil }, set: { if !$0 { connection.closeRequest = nil } })
    }

    var body: some View {
        ChromeGroup {
            header
            if expanded { content }
        }
        .chromeDialog(isPresented: $creating) {
            ChromeDialogSpec(
                title: "New Shell",
                message: "Opens a new shell in Turm on \(connection.name).",
                field: ChromeDialogSpec.Field(placeholder: "Folder (optional)"),
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Create") { directory in
                        connection.createShell(directory: directory) { id in
                            workspace.open(connection.session(for: id))
                        }
                    },
                ]
            )
        }
        .chromeDialog(isPresented: closeAlert) {
            let request = connection.closeRequest
            return ChromeDialogSpec(
                title: "Close this shell?",
                message: request?.message,
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Close Anyway", role: .destructive) { _ in
                        if let request { connection.closeSession(request.id, force: true) }
                    },
                ]
            )
        }
        .chromeDialog(isPresented: $forgetting) {
            .confirmation(
                title: "Forget \(connection.name)?",
                message: "This device loses access to the Mac. Pair again to reconnect.",
                confirm: "Forget"
            ) { macs.forget(connection.id) }
        }
    }

    private var header: some View {
        ChromeSwipeRow(actions: [
            ChromeSwipeAction(title: "Forget", systemImage: "trash", role: .destructive) { forgetting = true },
        ]) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                MacRow(mac: entry)
            }
            .rowSurface()
            .chromeTap {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            }
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .chromeContextMenu {
                [
                    ChromeMenuItem(title: "Refresh", systemImage: "arrow.clockwise", isEnabled: connection.state == .connected) {
                        connection.refreshSessions()
                    },
                    ChromeMenuItem(title: "Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = true },
                ]
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let advice = connection.updateAdvice {
            Label(advice, systemImage: "arrow.down.app")
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.warning)
                .multilineTextAlignment(.leading)
                .padding(.leading, 16)
                .rowSurface()
        }
        if let notice = connection.notice {
            Label(notice, systemImage: "exclamationmark.circle")
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.failure)
                .multilineTextAlignment(.leading)
                .padding(.leading, 16)
                .rowSurface()
                .chromeTap { connection.dismissNotice() }
        }
        switch connection.state {
        case .connected:
            if connection.sessions.isEmpty {
                Text("No shells open")
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.leading, 26)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            ForEach(connection.sessions) { summary in
                ChromeSwipeRow(actions: [
                    ChromeSwipeAction(title: "Close", systemImage: "xmark", role: .destructive) {
                        connection.closeSession(summary.id, force: false)
                    },
                ]) {
                    MacSessionRow(summary: summary)
                        .padding(.leading, 16)
                        .rowSurface(selected: summary.id == workspace.selectedID)
                        .chromeTap { workspace.open(connection.session(for: summary.id)) }
                        .chromeContextMenu {
                            [
                                ChromeMenuItem(title: "Close Session", systemImage: "xmark", role: .destructive) {
                                    connection.closeSession(summary.id, force: false)
                                },
                            ]
                        }
                }
            }
            SidebarAction(title: "New Shell", systemImage: "plus", indent: 16) { creating = true }
        case .failed:
            SidebarAction(title: "Try Again", systemImage: "arrow.clockwise", indent: 16) { connection.start() }
        case .offline, .connecting, .retrying:
            EmptyView()
        }
    }
}

struct MacSessionRow: View {
    let summary: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "Shell" : summary.title)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Text(summary.location)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                if let label = summary.remoteLabel, !label.isEmpty {
                    ChromeTag(text: label)
                }
            }
            Spacer(minLength: 8)
            ProgramMark(program: summary.program, activity: summary.activity, size: 20) {
                ActivityBadge(activity: summary.activity, phase: summary.phase)
            }
        }
    }
}

struct ActivityBadge: View {
    let activity: CompanionActivity
    let phase: CompanionPhase

    var body: some View {
        switch activity {
        case .working:
            ProgressView().controlSize(.small)
        case .progress(let percent):
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Chrome.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Chrome.failure)
        case .inactive:
            if phase == .running {
                Image(systemName: "ellipsis").foregroundStyle(Chrome.secondaryText)
            }
        }
    }
}
