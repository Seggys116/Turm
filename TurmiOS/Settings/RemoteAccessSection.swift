import SwiftUI
import TurmCore

struct RemoteAccessSection: View {
    var manager = MacManager.shared
    @State private var pairing = false

    var body: some View {
        ChromeSection(
            "Remote Access",
            footer: "Paired Macs let this device attach to their shells over an encrypted connection. Revoke a device on the Mac to remove its access."
        ) {
            ForEach(manager.macs) { entry in
                if let connection = manager.connection(for: entry.id) {
                    NavigationLink {
                        MacDetailView(connection: connection)
                    } label: {
                        row(entry, chevron: true)
                    }
                    .buttonStyle(RowPressStyle())
                } else {
                    Button { pairing = true } label: { row(entry, chevron: false) }
                        .buttonStyle(RowPressStyle())
                }
            }
            ChromeActionRow("Pair a Mac", systemImage: "link") { pairing = true }
        }
        .sheet(isPresented: $pairing) {
            PairMacView()
        }
    }

    private func row(_ entry: MacEntry, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            MacRow(mac: entry)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

struct MacDetailView: View {
    let connection: MacConnection
    var manager = MacManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [String]
    @State private var port: String
    @State private var newHost = ""
    @State private var confirmingForget = false

    init(connection: MacConnection) {
        self.connection = connection
        _hosts = State(initialValue: connection.record.hosts)
        _port = State(initialValue: String(connection.record.port == 0 ? Companion.defaultPort : connection.record.port))
    }

    private var portValue: UInt16? {
        UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var status: (text: String, color: Color) {
        switch connection.state {
        case .connected: ("Connected", Chrome.success)
        case .connecting: ("Connecting", Chrome.warning)
        case .offline: ("Not connected", Chrome.secondaryText)
        case .retrying(let reason), .failed(let reason): (reason, Chrome.failure)
        }
    }

    var body: some View {
        ChromeScroll {
            ChromeSection("Status") {
                ChromeRow("Connection") {
                    HStack(spacing: 6) {
                        StatusDot(color: status.color, size: 7)
                        Text(status.text)
                            .font(Chrome.Typeface.label)
                            .foregroundStyle(Chrome.secondaryText)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let advice = connection.updateAdvice {
                    ChromeRow("Update Available", detail: advice) { EmptyView() }
                }
                if let app = connection.remoteVersion?.app, !app.isEmpty {
                    ChromeRow("Turm on the Mac") {
                        Text(app)
                            .font(Chrome.Typeface.label)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                if connection.state != .connected {
                    ChromeActionRow("Connect Now", systemImage: "bolt") { connection.start() }
                }
            }
            ChromeSection(
                "Addresses",
                footer: "Nearby Macs are found automatically. Add an address to reach this Mac from other networks, for example its Tailscale name."
            ) {
                ForEach(hosts, id: \.self) { host in
                    ChromeSwipeRow(actions: [
                        ChromeSwipeAction(title: "Remove", systemImage: "trash", role: .destructive) { removeAddress(host) },
                    ]) {
                        HStack {
                            Text(host)
                                .font(Chrome.Typeface.monoBody)
                                .foregroundStyle(Chrome.text)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button {
                                Haptics.tap()
                                removeAddress(host)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Chrome.failure)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ChromePressStyle())
                            .accessibilityLabel("Remove \(host)")
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Address or Tailscale name", text: $newHost)
                        .font(Chrome.Typeface.monoBody)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(ChromeButtonStyle(compact: true))
                        .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                ChromeFieldRow("Port") {
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .onSubmit(save)
                }
            }
            ChromeGroup {
                ChromeActionRow("Forget This Mac", systemImage: "trash", role: .destructive) { confirmingForget = true }
            }
        }
        .chromeBar(ChromeTopBar(connection.name, leading: { ChromeBackButton { dismiss() } }))
        .onDisappear(perform: save)
        .onChange(of: connection.record.hosts) { _, learned in hosts = learned }
        .onChange(of: connection.record.port) { _, learned in port = String(learned == 0 ? Companion.defaultPort : learned) }
        .chromeDialog(isPresented: $confirmingForget) {
            .confirmation(
                title: "Forget \(connection.name)?",
                message: "This device loses access to the Mac. Pair again to reconnect. You can also revoke this device in Turm on the Mac.",
                confirm: "Forget"
            ) {
                manager.forget(connection.id)
                dismiss()
            }
        }
    }

    private func removeAddress(_ host: String) {
        hosts.removeAll { $0 == host }
        save()
    }

    private func add() {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hosts.contains(trimmed) else { return }
        hosts.append(trimmed)
        newHost = ""
        save()
    }

    private func save() {
        guard let portValue else { return }
        guard hosts != connection.record.hosts || portValue != connection.record.port else { return }
        connection.updateAddresses(hosts: hosts, port: portValue)
    }
}
