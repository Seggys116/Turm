import SwiftUI
import TurmCore

struct AppSidebar: View {
    let workspace: Workspace
    let macs: MacManager
    var hosts = SSHHostStore.shared
    @Environment(\.splitLayout) private var splitLayout

    var body: some View {
        ChromeScroll(spacing: 18) {
            sessionsSection
            macsSection
            hostsSection
        }
        .chromeBar(
            ChromeTopBar(
                "Turm",
                leading: {
                    if splitLayout { SidebarToggleButton(workspace: workspace) }
                },
                trailing: {
                    NewMenuButton(workspace: workspace)
                    SettingsButton(workspace: workspace)
                }
            )
            .environment(\.chromeBarShowsMark, true)
        )
        .background(Chrome.sidebar.ignoresSafeArea())
        .animation(.snappy(duration: 0.25), value: workspace.sessions.count)
    }

    @ViewBuilder
    private var sessionsSection: some View {
        if !workspace.sessions.isEmpty {
            ChromeSection("Open Sessions") {
                ForEach(workspace.sessions, id: \.id) { tab in
                    ChromeSwipeRow(actions: [closeAction(tab)]) {
                        SessionRow(tab: tab)
                            .rowSurface(selected: tab.id == workspace.selectedID)
                            .chromeTap { workspace.select(tab) }
                            .chromeContextMenu {
                                [ChromeMenuItem(title: "Close Session", systemImage: "xmark", role: .destructive) { workspace.close(tab) }]
                            }
                    }
                }
            }
        }
    }

    private var macsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(
                title: "Macs",
                action: ChromeSectionAction(systemImage: "plus", label: "Pair a Mac") { workspace.showsPairing = true }
            )
            if macs.macs.isEmpty {
                ChromeGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Macs yet")
                            .font(Chrome.Typeface.body)
                            .foregroundStyle(Chrome.text)
                        Text("Pair a Mac running Turm to open its shells from here.")
                            .font(Chrome.Typeface.caption)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    .rowSurface()
                    SidebarAction(title: "Pair a Mac", systemImage: "link") { workspace.showsPairing = true }
                }
            } else {
                ForEach(macs.macs) { entry in
                    if let connection = macs.connection(for: entry.id) {
                        MacGroup(workspace: workspace, macs: macs, connection: connection, entry: entry)
                    } else {
                        ChromeGroup {
                            MacRow(mac: entry)
                                .rowSurface()
                                .chromeTap { workspace.showsPairing = true }
                        }
                    }
                }
            }
        }
    }

    private var hostsSection: some View {
        ChromeSection(
            "SSH Hosts",
            action: ChromeSectionAction(systemImage: "plus", label: "Add SSH Host") { addHost() }
        ) {
            if hosts.hosts.isEmpty {
                SidebarAction(title: "Add an SSH Host", systemImage: "plus") { addHost() }
            } else {
                ForEach(hosts.hosts) { host in
                    ChromeSwipeRow(actions: [
                        ChromeSwipeAction(title: "Delete", systemImage: "trash", role: .destructive) { hosts.remove(host.id) },
                        ChromeSwipeAction(title: "Edit", systemImage: "pencil") { workspace.editingHost = host },
                    ]) {
                        HostRow(host: host)
                            .rowSurface()
                            .chromeTap { workspace.open(host) }
                            .chromeContextMenu {
                                [
                                    ChromeMenuItem(title: "Connect", systemImage: "terminal") { workspace.open(host) },
                                    ChromeMenuItem(title: "Edit", systemImage: "pencil") { workspace.editingHost = host },
                                    ChromeMenuItem(title: "Delete", systemImage: "trash", role: .destructive) { hosts.remove(host.id) },
                                ]
                            }
                    }
                }
            }
        }
    }

    private func closeAction(_ tab: any TerminalTab) -> ChromeSwipeAction {
        ChromeSwipeAction(title: "Close", systemImage: "xmark", role: .destructive) { workspace.close(tab) }
    }

    private func addHost() {
        workspace.editingHost = SSHHost(key: "", hostname: "")
    }
}

struct HostPicker: View {
    let workspace: Workspace
    var hosts = SSHHostStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
        .chromeBar(ChromeTopBar("New Session", trailing: { ChromeBarButton(title: "Cancel", systemImage: "xmark") { dismiss() } }))
        .chromeSheet()
    }

    private func addHost() {
        workspace.editingHost = SSHHost(key: "", hostname: "")
    }
}
