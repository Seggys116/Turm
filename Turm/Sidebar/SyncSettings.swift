import SwiftUI
import TurmCore

struct SyncSettings: View {
    var sync = CloudSync.shared
    var hosts = SSHHostStore.shared
    var identities = SSHIdentityStore.shared
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var keys: [SSHKey] = []
    @State private var queue: [String] = []
    @State private var pending: PendingKey?
    @State private var offered: [SSHKey] = []
    @State private var chosen: Set<String> = []
    @State private var offering = false
    @State private var message: String?

    private struct PendingKey: Identifiable {
        let id = UUID()
        let path: String
        let text: String
        var error: String?
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { sync.isEnabled },
            set: { on in
                if on { turnOn() } else { sync.disable() }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("iCloud Sync") {
                SettingsFormRow("Sync with iCloud", detail: "Keeps hosts, shortcuts, saved passwords and stored keys the same on your Mac and iPhone.") {
                    Toggle("Sync with iCloud", isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(SquareToggleStyle())
                        .disabled(deleting)
                }
                SettingsFormRow("Status", detail: statusDetail) {
                    HStack(spacing: 8) {
                        if sync.status == .deleting { ProgressView().controlSize(.small) }
                        Button("Sync Now") { sync.pull() }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(!sync.isEnabled || deleting)
                    }
                }
            }
            SettingsSection("What is synced") {
                SettingsFormRow("Hosts and shortcuts", detail: "Everything in the SSH and Shortcuts tabs. Interface settings and usage statistics stay on this Mac.") { EmptyView() }
                SettingsFormRow("Passwords and keys", detail: "SSH and sudo passwords you chose to remember, and keys stored in Turm. They travel only through iCloud Keychain, which is end-to-end encrypted.") { EmptyView() }
            }
            keysSection
            SettingsSection("Your data") {
                SettingsFormRow("Delete iCloud Data", detail: "Removes everything Turm has put in iCloud and turns sync off on every device.") {
                    Button("Delete iCloud Data...") { confirmingDelete = true }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(deleting)
                }
            }
            Text("Turning sync off only stops this Mac. It keeps its own copies of your hosts, shortcuts and passwords.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete iCloud data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete iCloud Data", role: .destructive) {
                deleting = true
                Task {
                    await sync.deleteCloudData()
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Synced passwords and keys are removed from iCloud and from the synced copies on your other devices, and sync is turned off everywhere. This Mac keeps its own local copies of your hosts, shortcuts, passwords and keys.")
        }
        .sheet(isPresented: $offering) { offerSheet }
        .sheet(item: $pending) { key in
            PassphraseSheet(key: key.path, error: key.error) { passphrase in
                finish(key, passphrase: passphrase)
            } cancel: {
                pending = nil
                advance()
            }
        }
    }

    private var keysSection: some View {
        SettingsSection("SSH Keys") {
            if keys.isEmpty {
                SettingsFormRow("None found", detail: "Private keys in ~/.ssh and key files named by your hosts appear here.") { EmptyView() }
            }
            ForEach(keys) { key in
                SettingsFormRow(key.name, detail: detail(for: key)) {
                    Toggle("Sync \(key.name)", isOn: stored(key))
                        .labelsHidden()
                        .toggleStyle(SquareToggleStyle())
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
            Text("A key you switch on is copied into Turm's keychain, so your iPhone can sign in with it when iCloud sync is on. The file on this Mac is never changed or deleted. Switching it off removes it from Turm and from your other devices.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private var offerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Also sync the keys your hosts use?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            Text("These keys are used by your hosts but are only on this Mac. Selected keys are stored in iCloud Keychain, which is end-to-end encrypted, and appear on your iPhone and iPad. The key files on this Mac stay as they are.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(offered) { key in
                Toggle(isOn: Binding(
                    get: { chosen.contains(key.path) },
                    set: { on in
                        if on { chosen.insert(key.path) } else { chosen.remove(key.path) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name).font(.system(size: 12, weight: .medium))
                        Text(usage(of: key)).font(.system(size: 10)).foregroundStyle(Theme.secondaryText.color)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not Now") { offering = false }
                    .keyboardShortcut(.cancelAction)
                Button("Sync Selected Keys") {
                    offering = false
                    queue = offered.map(\.path).filter(chosen.contains)
                    advance()
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(16)
        .frame(width: 400)
        .background(Theme.inputBackground.color)
    }

    private func stored(_ key: SSHKey) -> Binding<Bool> {
        Binding(
            get: { StoredKeys.identity(for: key) != nil },
            set: { on in
                message = nil
                if on {
                    queue = [key.path]
                    advance()
                } else if let identity = StoredKeys.identity(for: key) {
                    StoredKeys.remove(identity.id)
                    reload()
                }
            }
        )
    }

    private func turnOn() {
        sync.enable()
        guard sync.isEnabled else { return }
        reload()
        offered = keys.filter { !StoredKeys.hosts(using: $0).isEmpty && StoredKeys.identity(for: $0) == nil }
        chosen = Set(offered.map(\.path))
        offering = !offered.isEmpty
    }

    private func reload() {
        keys = StoredKeys.keys(discovered: SSHKeys.discover())
    }

    private func advance() {
        while !queue.isEmpty {
            let path = queue.removeFirst()
            do {
                let text = try StoredKeys.read(path: path)
                if try SSHIdentityStore.inspect(text).encrypted {
                    pending = PendingKey(path: path, text: text)
                    return
                }
                try StoredKeys.store(path: path, text: text, passphrase: nil)
            } catch {
                message = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
            }
        }
        reload()
    }

    private func finish(_ key: PendingKey, passphrase: String) {
        do {
            try StoredKeys.store(path: key.path, text: key.text, passphrase: passphrase.isEmpty ? nil : passphrase)
            pending = nil
            advance()
        } catch {
            pending?.error = error.localizedDescription
        }
    }

    private func usage(of key: SSHKey) -> String {
        let users = StoredKeys.hosts(using: key).map(\.token)
        return users.isEmpty ? "Not used by any host" : "Used by " + users.joined(separator: ", ")
    }

    private func detail(for key: SSHKey) -> String {
        var parts = [key.type.isEmpty ? nil : key.typeLabel, key.fingerprint, usage(of: key)].compactMap { $0 }
        if let identity = StoredKeys.identity(for: key) {
            parts.append(sync.isEnabled ? "Stored in Turm and synced as \(identity.name)" : "Stored in Turm, not synced while iCloud sync is off")
        } else {
            parts.append("Only on this Mac")
        }
        return parts.joined(separator: "  ")
    }

    private var statusDetail: String {
        switch sync.status {
        case .off: "Sync is off."
        case .active:
            if let last = sync.lastSync { "Last synced \(last.formatted(.relative(presentation: .named)))." } else { "Waiting for the first sync." }
        case .unavailable: "iCloud Keychain sync is not available to this build of Turm."
        case .resetElsewhere: "Sync was turned off because iCloud data was deleted from another device."
        case .deleting: "Deleting iCloud data..."
        }
    }
}

private struct PassphraseSheet: View {
    let key: String
    let error: String?
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Passphrase for \((key as NSString).lastPathComponent)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            Text("This key is encrypted. Turm keeps the passphrase in the keychain next to the key so your other devices can open it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
                .onSubmit { submit(passphrase) }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Store Key") { submit(passphrase) }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.inputBackground.color)
    }
}
