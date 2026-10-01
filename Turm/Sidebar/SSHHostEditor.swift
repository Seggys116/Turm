import AppKit
import SwiftUI
import TurmCore

struct SSHHostEditor: View {
    let close: () -> Void
    var store = SSHHostStore.shared
    @State private var draft: SSHHost
    @State private var portText: String
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    @State private var sudoPassword = ""
    @State private var hasSavedSudoPassword: Bool
    @State private var keys: [SSHKey] = SSHKeys.discover()
    @State private var detecting = false
    @State private var detectMessage: String?
    @State private var storingKey = false
    @State private var keyPassphrase = ""
    @State private var storeMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case key, hostname, user, port, password, sudoPassword }

    private static let chooseTag = "\u{0}choose"

    init(_ host: SSHHost, close: @escaping () -> Void) {
        self.close = close
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _hasSavedPassword = State(initialValue: SSHSecrets.shared.hasPassword(for: host))
        _hasSavedSudoPassword = State(initialValue: SSHSecrets.shared.hasPassword(for: host, slot: .sudo))
    }

    private var isNew: Bool { !store.hosts.contains { $0.id == draft.id } }
    private var cleanKey: String { Shortcuts.sanitize(draft.key) }
    private var conflict: SSHHost? { store.conflict(for: cleanKey, excluding: draft.id) }
    private var hostnameSet: Bool { !draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var port: Int? {
        let text = portText.trimmingCharacters(in: .whitespaces)
        return Int(text).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private var portValid: Bool { portText.trimmingCharacters(in: .whitespaces).isEmpty || port != nil }
    private var fieldProblem: String? { SSHHostValidation.problem(candidate()) }
    private var canSave: Bool { !cleanKey.isEmpty && conflict == nil && hostnameSet && portValid && fieldProblem == nil }

    private var keyOptions: [SSHKey] {
        guard let current = draft.identityFile, !current.isEmpty, !keys.contains(where: { $0.path == current }) else { return keys }
        return keys + [SSHKey(path: current, type: "", comment: "", fingerprint: nil)]
    }

    private static let storedTag = "\u{0}stored:"

    private var storedOnlyKeys: [SSHIdentity] {
        let covered = Set(keyOptions.compactMap { StoredKeys.identity(for: $0)?.id })
        return SSHIdentityStore.shared.identities.filter { !covered.contains($0.id) }
    }

    private var keySelection: Binding<String> {
        Binding(
            get: {
                if let file = draft.identityFile, !file.isEmpty { return file }
                if let id = draft.identityKeyID, SSHIdentityStore.shared.identity(id) != nil { return Self.storedTag + id.uuidString }
                return ""
            },
            set: { value in
                if value == Self.chooseTag {
                    if let path = Self.chooseKeyFile() { useFile(path) }
                } else if value.hasPrefix(Self.storedTag) {
                    draft.identityFile = nil
                    draft.identityKeyID = UUID(uuidString: String(value.dropFirst(Self.storedTag.count)))
                } else if value.isEmpty {
                    draft.identityFile = nil
                    draft.identityKeyID = nil
                } else {
                    useFile(value)
                }
            }
        )
    }

    private func useFile(_ path: String) {
        let known = keys.first { $0.path == path } ?? SSHKey(path: path, type: "", comment: "", fingerprint: nil)
        draft.identityFile = path
        draft.identityKeyID = StoredKeys.identity(for: known)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(isNew ? "Add" : "Edit") SSH Host")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            field("Name", hint: "Type >\(cleanKey.isEmpty ? "name" : cleanKey) in the input to connect.") {
                HStack(spacing: 2) {
                    Text(String(SSHHost.sigil)).foregroundStyle(Theme.secondaryText.color)
                    TextField("name", text: $draft.key)
                        .focused($focus, equals: .key)
                        .onChange(of: draft.key) { _, new in
                            let cleaned = Shortcuts.sanitize(new)
                            if cleaned != new { draft.key = cleaned }
                        }
                }
            }
            field("Host", hint: "A hostname, an address or a Host alias from ~/.ssh/config.") {
                TextField("example.com", text: $draft.hostname)
                    .focused($focus, equals: .hostname)
            }
            HStack(alignment: .top, spacing: 8) {
                field("User", hint: nil) {
                    TextField("Optional", text: $draft.user)
                        .focused($focus, equals: .user)
                }
                field("Port", hint: nil) {
                    TextField("22", text: $portText)
                        .focused($focus, equals: .port)
                }
                .frame(width: 80)
            }
            if !portValid {
                Text("The port must be a number from 1 to 65535.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
            }
            if let fieldProblem {
                Text(fieldProblem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            keyField
            storedKeyField
            passwordField
            sudoField
            if let conflict {
                Text("\(conflict.token) is already used by \(conflict.summary).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.inputBackground.color)
        .onSubmit(save)
        .onAppear { focus = .key }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText.color)
            HStack(spacing: 8) {
                Picker("Key", selection: keySelection) {
                    Text("Default keys").tag("")
                    ForEach(keyOptions) { key in
                        Text(label(for: key)).tag(key.path)
                    }
                    ForEach(storedOnlyKeys) { identity in
                        Text("\(identity.name)  \(identity.algorithm)  (stored in Turm)").tag(Self.storedTag + identity.id.uuidString)
                    }
                    Divider()
                    Text("Choose File...").tag(Self.chooseTag)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button(action: detect) {
                    HStack(spacing: 6) {
                        if detecting { ProgressView().controlSize(.small) }
                        Text("Detect")
                    }
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!hostnameSet || detecting)
            }
            if let detectMessage {
                Text(detectMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var storedIdentity: SSHIdentity? {
        draft.identityKeyID.flatMap { SSHIdentityStore.shared.identity($0) }
    }

    @ViewBuilder
    private var storedKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let identity = storedIdentity {
                HStack(spacing: 8) {
                    Text("Stored in Turm: \(identity.name) (\(identity.algorithm))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Remove", action: removeStoredKey)
                        .buttonStyle(SettingsButtonStyle())
                }
            } else if let path = draft.identityFile, !path.isEmpty {
                if storingKey {
                    field("Key passphrase", hint: "Leave empty if the key has none. The key and passphrase are kept in the keychain, never in a file.") {
                        SecureField("Optional", text: $keyPassphrase)
                    }
                    HStack(spacing: 8) {
                        Button("Store Key") { storeKey(path) }
                            .buttonStyle(SettingsButtonStyle(prominent: true))
                        Button("Cancel") {
                            storingKey = false
                            keyPassphrase = ""
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                } else {
                    Button("Store Key in Turm...") {
                        storeMessage = nil
                        storingKey = true
                    }
                    .buttonStyle(SettingsButtonStyle())
                    Text("Keeps a copy of this key in the keychain so your iPhone can use it when iCloud sync is on.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let storeMessage {
                Text(storeMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func storeKey(_ path: String) {
        defer {
            keyPassphrase = ""
            storingKey = false
        }
        do {
            let text = try StoredKeys.read(path: path)
            let identity = try StoredKeys.store(path: path, text: text, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
            draft.identityKeyID = identity.id
            storeMessage = "Stored. Save the host to finish."
        } catch {
            storeMessage = error.localizedDescription
        }
    }

    private func removeStoredKey() {
        guard let id = draft.identityKeyID else { return }
        StoredKeys.remove(id)
        draft.identityKeyID = nil
        storeMessage = "Removed from Turm. Save the host to finish."
    }

    private var passwordField: some View {
        field("Password", hint: draft.remembersPassword ? (CloudSync.shared.isEnabled ? "Stored in iCloud Keychain and shared with your devices." : "Stored in the Keychain on this Mac.") : "Without Remember in Keychain, the password is used only until Turm quits.") {
            HStack(spacing: 6) {
                SecureField(hasSavedPassword ? "Saved" : "Optional", text: $password)
                    .focused($focus, equals: .password)
                if hasSavedPassword {
                    Button("Clear") {
                        SSHSecrets.shared.forget(draft.id)
                        hasSavedPassword = false
                        password = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText.color)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Toggle("Remember in Keychain", isOn: $draft.remembersPassword)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
        }
    }

    private var sudoField: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fill sudo password")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText.color)
                Picker("Fill sudo password", selection: $draft.sudoFill) {
                    Text("Off").tag(SSHHost.SudoFill.off)
                    Text("Ask").tag(SSHHost.SudoFill.ask)
                    Text("Automatic").tag(SSHHost.SudoFill.automatic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(sudoHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.sudoFill != .off {
                field("Sudo Password", hint: "Leave empty to use the login password. Needs Turm integration on the host.") {
                    HStack(spacing: 6) {
                        SecureField(hasSavedSudoPassword ? "Saved" : "Same as login password", text: $sudoPassword)
                            .focused($focus, equals: .sudoPassword)
                        if hasSavedSudoPassword {
                            Button("Clear") {
                                SSHSecrets.shared.forget(draft.id, slot: .sudo)
                                hasSavedSudoPassword = false
                                sudoPassword = ""
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondaryText.color)
                        }
                    }
                }
            }
        }
    }

    private var sudoHint: String {
        switch draft.sudoFill {
        case .off: "Never fill sudo prompts on this host."
        case .ask: "Offers a button when a command you typed with sudo shows its own password prompt."
        case .automatic: "Fills once when a command you typed with sudo shows its own password prompt."
        }
    }

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText.color)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(for key: SSHKey) -> String {
        [key.name, key.type.isEmpty ? nil : key.typeLabel, key.comment.isEmpty ? nil : key.comment]
            .compactMap { $0 }
            .joined(separator: "  ")
    }

    private func candidate() -> SSHHost {
        var host = draft
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        host.port = port
        return host
    }

    private func detect() {
        let host = candidate()
        let found = keys
        detecting = true
        detectMessage = nil
        Task {
            let result = await SSHKeys.detect(host, keys: found)
            detecting = false
            switch result {
            case .accepted(let path, let authenticated):
                useFile(path)
                let name = (path as NSString).lastPathComponent
                detectMessage = "Server accepts \(name)" + (authenticated ? "" : " (needs its passphrase or ssh-agent)")
            case .none:
                detectMessage = "No local key was accepted"
            case .hostKeyUnknown:
                detectMessage = "Connect once to trust this host's key, then detect again"
            case .unreachable(let message):
                detectMessage = message
            }
        }
    }

    private func save() {
        guard canSave else { return }
        var host = candidate()
        host.key = cleanKey
        let wasNew = isNew
        let previous = store.hosts.first { $0.id == host.id }
        let moved = previous?.remembersPassword != host.remembersPassword
        let carried = password.isEmpty && moved ? previous.flatMap { SSHSecrets.shared.password(for: $0) } : nil
        let carriedSudo = sudoPassword.isEmpty && moved ? previous.flatMap { SSHSecrets.shared.password(for: $0, slot: .sudo) } : nil
        guard store.save(host) else { return }
        if !password.isEmpty {
            SSHSecrets.shared.set(password, for: host)
        } else if let carried {
            SSHSecrets.shared.set(carried, for: host)
        }
        if !sudoPassword.isEmpty {
            SSHSecrets.shared.set(sudoPassword, for: host, slot: .sudo)
        } else if let carriedSudo {
            SSHSecrets.shared.set(carriedSudo, for: host, slot: .sudo)
        }
        if wasNew, host.identityFile == nil {
            autoDetect(host)
        }
        close()
    }

    private func autoDetect(_ host: SSHHost) {
        let found = keys
        Task {
            guard case .accepted(let path, _) = await SSHKeys.detect(host, keys: found),
                  var current = store.hosts.first(where: { $0.id == host.id }),
                  current.identityFile == nil
            else { return }
            current.identityFile = path
            store.save(current)
        }
    }

    private static func chooseKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh", isDirectory: true)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}
