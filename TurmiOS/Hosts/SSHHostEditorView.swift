import SwiftUI
import TurmCore

struct SSHHostEditorView: View {
    let close: () -> Void
    var store = SSHHostStore.shared
    var identities = SSHIdentityStore.shared
    @State private var draft: SSHHost
    @State private var portText: String
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    @FocusState private var focus: Field?

    private enum Field { case key, hostname, user, port, password }

    init(_ host: SSHHost, close: @escaping () -> Void) {
        self.close = close
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _hasSavedPassword = State(initialValue: SSHSecrets.shared.hasPassword(for: host))
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
    private var problem: String? {
        var candidate = draft
        candidate.port = port
        return SSHHostValidation.problem(candidate)
    }

    private var canSave: Bool { !cleanKey.isEmpty && conflict == nil && hostnameSet && portValid && problem == nil }

    var body: some View {
        ChromeScroll {
            nameSection
            connectionSection
            authenticationSection
        }
        .chromeBar(
            ChromeTopBar(
                isNew ? "Add SSH Host" : "Edit SSH Host",
                leading: { ChromeBarButton(title: "Cancel", systemImage: "xmark", action: close) },
                trailing: { ChromeBarButton(title: "Save", systemImage: "checkmark", kind: .prominent, action: save).disabled(!canSave) }
            )
        )
        .onAppear { if isNew { focus = .key } }
        .chromeSheet()
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSection("Name") {
                ChromeFieldRow("Name") {
                    HStack(spacing: 2) {
                        Text(String(SSHHost.sigil)).foregroundStyle(Chrome.secondaryText)
                        TextField("name", text: $draft.key)
                            .focused($focus, equals: .key)
                            .onChange(of: draft.key) { _, new in
                                let cleaned = Shortcuts.sanitize(new)
                                if cleaned != new { draft.key = cleaned }
                            }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }
            if let conflict {
                note("\(conflict.token) is already used by \(conflict.summary).", failure: true)
            } else {
                note("Also the name used with > in Turm on your Mac.", failure: false)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSection("Connection") {
                ChromeFieldRow("Host") {
                    TextField("example.com", text: $draft.hostname)
                        .focused($focus, equals: .hostname)
                        .keyboardType(.URL)
                }
                ChromeFieldRow("User") {
                    TextField("Optional", text: $draft.user)
                        .focused($focus, equals: .user)
                }
                ChromeFieldRow("Port") {
                    TextField("22", text: $portText)
                        .focused($focus, equals: .port)
                        .keyboardType(.numberPad)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !portValid {
                note("The port must be a number from 1 to 65535.", failure: true)
            } else if let problem {
                note(problem, failure: true)
            }
        }
    }

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSection("Authentication") {
                ChromeRow("Sign in with") {
                    ChromeMenuField(value: signInName, label: "Sign in with", items: signInItems)
                }
                if draft.identityKeyID == nil {
                    ChromeFieldRow("Password") {
                        SecureField(hasSavedPassword ? "Saved" : "Optional", text: $password)
                            .focused($focus, equals: .password)
                    }
                    ChromeRow("Remember in Keychain") {
                        Toggle("Remember in Keychain", isOn: $draft.remembersPassword)
                            .labelsHidden()
                            .tint(Chrome.accent)
                    }
                    if hasSavedPassword {
                        ChromeActionRow("Clear Saved Password", systemImage: "trash", role: .destructive) {
                            SSHSecrets.shared.forget(draft.id)
                            hasSavedPassword = false
                            password = ""
                        }
                    }
                }
            }
            note(authenticationHint, failure: false)
        }
    }

    private var signInName: String {
        identities.identities.first { $0.id == draft.identityKeyID }?.name ?? "Password"
    }

    private func signInItems() -> [ChromeMenuItem] {
        let current = draft.identityKeyID
        var items = [ChromeMenuItem(title: "Password", isOn: current == nil) { draft.identityKeyID = nil }]
        for identity in identities.identities {
            items.append(ChromeMenuItem(title: identity.name, isOn: current == identity.id) { draft.identityKeyID = identity.id })
        }
        return items
    }

    private func note(_ text: String, failure: Bool) -> some View {
        Text(text)
            .font(Chrome.Typeface.caption)
            .foregroundStyle(failure ? Chrome.failure : Chrome.secondaryText)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var authenticationHint: String {
        if draft.identityKeyID != nil { return "Turm signs in with the selected key. Import keys in Settings." }
        return draft.remembersPassword
            ? (CloudSync.shared.isEnabled ? "Stored in iCloud Keychain and shared with your devices." : "Stored in the Keychain on this device.")
            : "Without Remember in Keychain, the password is kept only until Turm quits."
    }

    private func save() {
        guard canSave else { return }
        var host = draft
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        host.port = port
        host.key = cleanKey
        let previous = store.hosts.first { $0.id == host.id }
        let moved = previous?.remembersPassword != host.remembersPassword
        let carried = password.isEmpty && moved ? previous.flatMap { SSHSecrets.shared.password(for: $0) } : nil
        guard store.save(host) else { return }
        if !password.isEmpty {
            SSHSecrets.shared.set(password, for: host)
        } else if let carried {
            SSHSecrets.shared.set(carried, for: host)
        }
        Haptics.confirm()
        close()
    }
}
