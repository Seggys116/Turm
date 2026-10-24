import SwiftUI
import TurmCore

enum HomeRoute: Hashable {
    case mac(String)
    case space(mac: String, space: String)
}

struct AppSidebar: View {
    @Bindable var workspace: Workspace
    let macs: MacManager
    @Binding var path: [HomeRoute]
    #if targetEnvironment(simulator)
    var hosts = DemoContent.hosts ?? SSHHostStore.shared
    #else
    var hosts = SSHHostStore.shared
    #endif
    @State private var query = ""

    var body: some View {
        List(selection: $workspace.selectedID) {
            sessionsSection
            hostsSection
            macsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Turm")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search hosts and devices")
        .modifier(BottomSearch())
        .toolbar { sidebarToolbar }
        .background(Chrome.sidebar.ignoresSafeArea())
        .sessionDrop(into: workspace)
        .animation(.snappy(duration: 0.25), value: workspace.sessions.count)
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("New", systemImage: "plus") {
                Button("New Session", systemImage: "terminal") { workspace.showsHostPicker = true }
                Button("New SSH Host", systemImage: "network") { workspace.editingHost = SSHHost(key: "", hostname: "") }
                Button("Pair a Mac", systemImage: "link") { workspace.showsPairing = true }
            }
            Button("Settings", systemImage: "gearshape") { workspace.showsSettings = true }
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        let shown = filteredSessions
        if !shown.isEmpty {
            Section("Open Sessions") {
                ForEach(shown, id: \.id) { tab in
                    SessionRow(tab: tab)
                        .tag(tab.id as UUID?)
                        .sessionDrag(tab)
                        .swipeActions(edge: .trailing) {
                            Button("Close", role: .destructive) { workspace.close(tab) }
                        }
                        .contextMenu {
                            Button("Close Session", systemImage: "xmark", role: .destructive) { workspace.close(tab) }
                        }
                }
            }
        }
    }

    private var filteredSessions: [any TerminalTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return workspace.sessions }
        return workspace.sessions.filter {
            $0.title.localizedStandardContains(needle) || $0.subtitle.localizedStandardContains(needle)
        }
    }

    private var macsSection: some View {
        Section {
            if visibleMacs.isEmpty {
                Button("Pair a Mac", systemImage: "link") { workspace.showsPairing = true }
            } else {
                ForEach(visibleMacs) { entry in
                    if let connection = macs.connection(for: entry.id) {
                        Button {
                            path.append(.mac(entry.id))
                        } label: {
                            HStack(spacing: 8) {
                                MacRow(mac: entry)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Button {
                            workspace.showsPairing = true
                        } label: {
                            MacRow(mac: entry)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Mac")
                Spacer()
                Button("Pair a Mac", systemImage: "plus") { workspace.showsPairing = true }
                    .labelStyle(.iconOnly)
            }
        } footer: {
            Text("Open a Mac to use the spaces on that machine.")
        }
    }

    private var visibleMacs: [MacEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return macs.macs }
        return macs.macs.filter {
            $0.name.localizedStandardContains(needle) || $0.detail.localizedStandardContains(needle)
        }
    }

    private var hostsSection: some View {
        Section {
            if visibleHosts.isEmpty {
                Button("Add an SSH Host", systemImage: "plus") { addHost() }
            } else {
                ForEach(visibleHosts) { host in
                    Button {
                        workspace.open(host)
                    } label: {
                        HostRow(host: host, connected: isConnected(host))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { hosts.remove(host.id) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Edit") { workspace.editingHost = host }
                    }
                    .contextMenu {
                        Button("Connect", systemImage: "terminal") { workspace.open(host) }
                        Button("Edit", systemImage: "pencil") { workspace.editingHost = host }
                        Button("Delete", systemImage: "trash", role: .destructive) { hosts.remove(host.id) }
                    }
                }
            }
        } header: {
            HStack {
                Text("SSH Hosts")
                Spacer()
                Button("Add SSH Host", systemImage: "plus") { addHost() }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var visibleHosts: [SSHHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return hosts.hosts }
        return hosts.hosts.filter {
            $0.key.localizedStandardContains(needle) || $0.hostname.localizedStandardContains(needle)
        }
    }

    private func isConnected(_ host: SSHHost) -> Bool {
        workspace.sessions.contains { ($0 as? SSHTerminalSession)?.host.id == host.id }
    }

    private func addHost() {
        workspace.editingHost = SSHHost(key: "", hostname: "")
    }
}

private struct BottomSearch: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
        } else {
            content
        }
    }
}

struct HostPicker: View {
    let workspace: Workspace
    #if targetEnvironment(simulator)
    var hosts = DemoContent.hosts ?? SSHHostStore.shared
    #else
    var hosts = SSHHostStore.shared
    #endif
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
        ChromeScroll {
            ChromeSection("SSH Hosts") {
                ForEach(hosts.hosts) { host in
                    Button {
                        dismiss()
                        workspace.open(host)
                    } label: {
                        HStack {
                            HostRow(host: host)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPressStyle())
                }
                ChromeActionRow("Add SSH Host", systemImage: "plus") {
                    dismiss()
                    addHost()
                }
            }
        }
        .navigationTitle("New Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        }
        .chromeSheet()
    }

    private func addHost() {
        workspace.editingHost = SSHHost(key: "", hostname: "")
    }
}
