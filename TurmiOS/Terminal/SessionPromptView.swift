import SwiftUI
import TurmCore

struct SessionPromptView: View {
    let session: SSHTerminalSession

    var body: some View {
        if let prompt = session.prompt {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                ScrollView {
                    card(for: prompt)
                        .padding(18)
                        .frame(maxWidth: 420)
                        .background(Chrome.topBar, in: RoundedRectangle(cornerRadius: Chrome.Radius.group + 4))
                        .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.group + 4).stroke(Chrome.divider, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func card(for prompt: SSHTerminalSession.Prompt) -> some View {
        switch prompt {
        case .credentials(let request):
            CredentialCard(session: session, request: request)
        case .passphrase(let request):
            PassphraseCard(session: session, request: request).id(request.id)
        case .trustHostKey(let request):
            HostKeyCard(session: session, request: request, changed: false)
        case .hostKeyChanged(let request):
            HostKeyCard(session: session, request: request, changed: true)
        case .integration(let offer):
            IntegrationCard(session: session, offer: offer)
        }
    }
}

private struct IntegrationCard: View {
    let session: SSHTerminalSession
    let offer: SSHTerminalSession.IntegrationOffer

    private var heading: String {
        switch offer {
        case .install: "Use Turm blocks on \(session.host.key)?"
        case .update: "Update Turm integration on \(session.host.key)?"
        }
    }

    private var message: String {
        switch offer {
        case .install(let shell):
            "\(session.host.key) runs \(shell) without Turm integration. Install it to keep blocks, exit codes and the working folder over SSH. Turm writes a few small scripts to ~/.turm/shell; your own shell files are not changed."
        case .update:
            "Turm integration on \(session.host.key) is older than this version of Turm. Update it to keep blocks working as they should."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.text)
                Text(session.host.summary)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
            }
            Text(message)
                .font(Chrome.Typeface.label)
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    Haptics.confirm()
                    session.answerIntegration(.install)
                } label: {
                    Text(isInstall ? "Install" : "Update")
                }
                .buttonStyle(ChromeButtonStyle(kind: .prominent))
                .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    Button("Not Now") { session.answerIntegration(.notNow) }
                        .buttonStyle(ChromeButtonStyle())
                        .frame(maxWidth: .infinity)
                    if isInstall {
                        Button("Never for This Host") { session.answerIntegration(.never) }
                            .buttonStyle(ChromeButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var isInstall: Bool {
        if case .install = offer { return true }
        return false
    }
}

private struct CredentialCard: View {
    let session: SSHTerminalSession
    let request: SSHTerminalSession.CredentialRequest
    @State private var user: String
    @State private var password = ""
    @State private var remember: Bool
    @FocusState private var focus: Field?

    private enum Field { case user, password }

    init(session: SSHTerminalSession, request: SSHTerminalSession.CredentialRequest) {
        self.session = session
        self.request = request
        _user = State(initialValue: session.host.user)
        _remember = State(initialValue: session.host.remembersPassword)
    }

    private var canSubmit: Bool {
        (!request.needsUsername || !user.trimmingCharacters(in: .whitespaces).isEmpty)
            && (!request.needsPassword || !password.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.needsPassword ? "Password for \(session.host.key)" : "User for \(session.host.key)")
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.text)
                Text(session.host.summary)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
            }
            if request.needsUsername {
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .user)
                    .submitLabel(request.needsPassword ? .next : .go)
                    .onSubmit { request.needsPassword ? (focus = .password) : submit() }
                    .promptField()
            }
            if request.needsPassword {
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .promptField()
                Toggle("Remember in Keychain", isOn: $remember)
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.secondaryText)
                    .tint(Chrome.accent)
            }
            HStack(spacing: 10) {
                Button("Cancel", action: session.cancelPrompt)
                    .buttonStyle(ChromeButtonStyle())
                Button("Connect", action: submit)
                    .buttonStyle(ChromeButtonStyle(kind: .prominent))
                    .disabled(!canSubmit)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { focus = request.needsUsername && user.isEmpty ? .user : .password }
    }

    private func submit() {
        guard canSubmit else { return }
        Haptics.tap()
        session.answerCredentials(user: user, password: password, remember: remember)
    }
}

private struct PassphraseCard: View {
    let session: SSHTerminalSession
    let request: SSHTerminalSession.PassphraseRequest
    @State private var passphrase = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Passphrase for \(request.keyName)")
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.text)
                Text(request.algorithm)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
            }
            SecureField("Passphrase", text: $passphrase)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .promptField()
            if request.wrong {
                Text("That passphrase did not unlock the key. Try again.")
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.failure)
            }
            Toggle("Remember in Keychain", isOn: $remember)
                .font(Chrome.Typeface.label)
                .foregroundStyle(Chrome.secondaryText)
                .tint(Chrome.accent)
            HStack(spacing: 10) {
                Button("Cancel", action: session.cancelPrompt)
                    .buttonStyle(ChromeButtonStyle())
                Button("Unlock", action: submit)
                    .buttonStyle(ChromeButtonStyle(kind: .prominent))
                    .disabled(passphrase.isEmpty)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            focused = true
            if request.wrong { Haptics.warn() }
        }
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        Haptics.tap()
        session.answerPassphrase(passphrase, remember: remember)
    }
}

private struct HostKeyCard: View {
    let session: SSHTerminalSession
    let request: SSHTerminalSession.HostKeyRequest
    let changed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if changed {
                Label("Host key changed", systemImage: "exclamationmark.triangle.fill")
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.failure)
                Text("The key presented by \(request.host):\(request.port) is different from the one saved earlier. Someone may be intercepting the connection. Turm refused to connect.")
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.text)
            } else {
                Text("Trust this host?")
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.text)
                Text("Turm has not connected to \(request.host):\(request.port) before. Check the fingerprint with the server's owner if you can.")
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.secondaryText)
            }
            VStack(alignment: .leading, spacing: 10) {
                fingerprint("Presented \(request.algorithm)", request.fingerprint, highlight: changed)
                if let previous = request.previousFingerprint {
                    fingerprint("Saved", previous, highlight: false)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chrome.inputBackground, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
            HStack(spacing: 10) {
                if changed {
                    Button("Forget Saved Key", action: session.forgetChangedKey)
                        .buttonStyle(ChromeButtonStyle(kind: .destructive))
                    Button("Dismiss", action: session.cancelPrompt)
                        .buttonStyle(ChromeButtonStyle(kind: .prominent))
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Cancel") { session.answerHostKey(trust: false) }
                        .buttonStyle(ChromeButtonStyle())
                    Button("Trust and Connect") {
                        Haptics.confirm()
                        session.answerHostKey(trust: true)
                    }
                    .buttonStyle(ChromeButtonStyle(kind: .prominent))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { if changed { Haptics.warn() } }
    }

    private func fingerprint(_ title: String, _ value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.secondaryText)
            Text(value)
                .font(Chrome.Typeface.mono)
                .foregroundStyle(highlight ? Chrome.failure : Chrome.text)
                .textSelection(.enabled)
        }
    }
}
