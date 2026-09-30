import SwiftUI

struct SSHSettings: View {
    var store = SSHHostStore.shared
    @State private var editing: UUID?
    @State private var adding: SSHHost?
    @State private var configNames: [String] = []
    @State private var installed: [SSHTarget] = []
    @State private var uninstalling: Set<String> = []
    @State private var failures: [String: String] = [:]
    @AppStorage(SSHHostStore.offerKey) private var offersIntegration = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            hostsSection
            importSection
            integrationSection
            Text("Turm installs its prompt hooks into ~/.turm/shell on the server and never edits the server's shell startup files. Sessions from other terminals are unaffected.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
            Text("Passwords are only kept in the macOS Keychain when Remember in Keychain is on. Otherwise they are held in memory until Turm quits. Keys are preferred.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .onAppear(perform: reload)
    }

    private var hostsSection: some View {
        SettingsSection("Hosts  \(SSHHost.sigil)") {
            if store.hosts.isEmpty {
                SettingsFormRow("None yet", detail: "Type >name in the input to connect.") { EmptyView() }
            }
            ForEach(store.hosts) { host in
                SettingsFormRow(host.token + "  " + host.summary, detail: describe(host)) {
                    HStack(spacing: 8) {
                        Button("Edit") { editing = host.id }
                            .popover(isPresented: isEditing(host.id), arrowEdge: .bottom) {
                                SSHHostEditor(host) {
                                    editing = nil
                                    reload()
                                }
                            }
                        Button("Remove") {
                            store.remove(host.id)
                            reload()
                        }
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
            SettingsFormRow("Add a host", detail: nil) {
                Button("Add Host...") { adding = SSHHost(key: "", hostname: "") }
                    .buttonStyle(SettingsButtonStyle())
                    .popover(isPresented: isAdding, arrowEdge: .bottom) {
                        if let adding {
                            SSHHostEditor(adding) {
                                self.adding = nil
                                reload()
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var importSection: some View {
        let names = store.importable(from: configNames)
        SettingsSection("Import from SSH config") {
            if names.isEmpty {
                SettingsFormRow("Nothing new found", detail: "Every Host in ~/.ssh/config is already saved.") { EmptyView() }
            } else {
                ForEach(names, id: \.self) { name in
                    SettingsFormRow(name, detail: nil) {
                        Button("Import") { importHost(name) }
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
                SettingsFormRow("Import all", detail: "\(names.count) hosts from ~/.ssh/config") {
                    Button("Import All") { names.forEach(importHost) }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private var integrationSection: some View {
        SettingsSection("Remote shell integration") {
            SettingsFormRow("Offer to install on new hosts", detail: "Ask once per server whether Turm may add its prompt hooks.") {
                Toggle("Offer to install on new hosts", isOn: $offersIntegration)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
            }
            ForEach(installed, id: \.identifier) { target in
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFormRow(target.identifier, detail: "Installed") {
                        HStack(spacing: 8) {
                            if uninstalling.contains(target.identifier) {
                                ProgressView().controlSize(.small)
                            }
                            Button("Uninstall") { uninstall(target) }
                                .help("Remove the files from the server and stop using them.")
                            Button("Forget") {
                                RemoteIntegration.removeMarker(target)
                                reload()
                            }
                            .help("Stop launching through the integration but leave the files on the server.")
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(uninstalling.contains(target.identifier))
                    }
                    if let message = failures[target.identifier] {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
            ForEach(store.declined, id: \.self) { identifier in
                SettingsFormRow(identifier, detail: "Declined") {
                    Button("Allow again") { store.allow(identifier) }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private func describe(_ host: SSHHost) -> String {
        var parts = [host.identityFile.map { ($0 as NSString).lastPathComponent } ?? "Automatic key"]
        if SSHSecrets.shared.hasPassword(for: host) {
            parts.append(host.remembersPassword ? "password saved" : "password for this session")
        }
        if host.sudoFill != .off {
            parts.append(host.sudoFill == .ask ? "sudo fill: ask" : "sudo fill: automatic")
        }
        if installed.contains(where: host.matches) {
            parts.append("Turm integration installed")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func isEditing(_ id: UUID) -> Binding<Bool> {
        Binding(get: { editing == id }, set: { if !$0, editing == id { editing = nil } })
    }

    private var isAdding: Binding<Bool> {
        Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })
    }

    private func reload() {
        var names: [String] = []
        ArgumentSources.collectSSHConfig(path: NSHomeDirectory() + "/.ssh/config", env: SystemCompletionEnvironment.shared, depth: 0, into: &names)
        configNames = names
        installed = RemoteIntegration.installedTargets()
    }

    private func importHost(_ alias: String) {
        store.save(SSHHost(key: Shortcuts.sanitize(alias), hostname: alias))
    }

    private func uninstall(_ target: SSHTarget) {
        let identifier = target.identifier
        failures[identifier] = nil
        uninstalling.insert(identifier)
        Task {
            let failure = await RemoteIntegration.uninstall(target)
            uninstalling.remove(identifier)
            if let failure {
                failures[identifier] = failure
            } else {
                RemoteIntegration.removeMarker(target)
                reload()
            }
        }
    }
}
