import Citadel
import Foundation
import NIOCore
import NIOSSH
import Observation
import TurmCore
import UIKit

@Observable
final class SSHTerminalSession: Identifiable, TerminalTab {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
        case failed(String)
    }

    struct CredentialRequest {
        var needsUsername: Bool
        var needsPassword: Bool
    }

    struct HostKeyRequest {
        var host: String
        var port: Int
        var algorithm: String
        var fingerprint: String
        var previousFingerprint: String?
    }

    struct PassphraseRequest {
        let id = UUID()
        var keyName: String
        var algorithm: String
        var wrong: Bool
    }

    enum IntegrationOffer: Equatable {
        case install(shell: String)
        case update(shell: String)
    }

    enum IntegrationChoice {
        case install
        case notNow
        case never
    }

    struct IntegrationNotice: Equatable {
        var text: String
        var offersDecline = false
    }

    enum Prompt {
        case credentials(CredentialRequest)
        case passphrase(PassphraseRequest)
        case trustHostKey(HostKeyRequest)
        case hostKeyChanged(HostKeyRequest)
        case integration(IntegrationOffer)
    }

    private struct KeyPlan {
        var user: String
        var identities: [SSHIdentity]
        var explicit: Bool
    }

    private enum KeyOutcome {
        case method(SSHAuthenticationMethod)
        case skip
        case cancelled
    }


    private enum Input: Sendable {
        case data([UInt8])
        case resize(Int, Int)
    }

    private static let helloWait: Duration = .seconds(15)
    private static let viewportSettle: Duration = .milliseconds(150)

    let id = UUID()
    let surface: TerminalSurface
    let shell = SSHShell()
    private(set) var host: SSHHost
    private(set) var state = State.idle
    private(set) var title: String
    private(set) var usesBlocks = false
    private(set) var integrationActivity: String?
    private(set) var integrationNotice: IntegrationNotice?
    var prompt: Prompt?
    var editor: ShortcutTarget?
    var showsBranches = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var channelInput: AsyncStream<Input>.Continuation?
    @ObservationIgnored private var credentialWaiter: CheckedContinuation<(user: String, password: String, remember: Bool)?, Never>?
    @ObservationIgnored private var passphraseWaiter: CheckedContinuation<(passphrase: String, remember: Bool)?, Never>?
    @ObservationIgnored private var hostKeyWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var integrationWaiter: CheckedContinuation<IntegrationChoice, Never>?
    @ObservationIgnored private var helloTimer: Task<Void, Never>?
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var viewport = CGSize.zero
    @ObservationIgnored private var fontSize = TerminalPreferences.defaultSize
    @ObservationIgnored private var gitGeneration = 0
    @ObservationIgnored private var useStoredPassword = true
    @ObservationIgnored private var hostKeyRefused = false
    @ObservationIgnored private var wasBackgrounded = false
    @ObservationIgnored private var lastOutput = ContinuousClock.now
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(host: SSHHost, surface: TerminalSurface = TerminalSurface()) {
        self.host = host
        self.surface = surface
        title = host.key
        surface.onInput = { [weak self] bytes in
            guard let self, !usesBlocks else { return }
            channelInput?.yield(.data(Array(bytes)))
        }
        surface.onResize = { [weak self] cols, rows in
            guard let self, !usesBlocks else { return }
            channelInput?.yield(.resize(cols, rows))
        }
        surface.onTitle = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            title = text
        }
        shell.send = { [weak self] bytes in self?.channelInput?.yield(.data(bytes)) }
        shell.resizeTerminal = { [weak self] cols, rows in self?.channelInput?.yield(.resize(cols, rows)) }
        shell.onEstablished = { [weak self] in self?.integrationStarted() }
        shell.onPrompt = { [weak self] path in self?.refreshGit(in: path) }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wasBackgrounded = true }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isLive: Bool {
        switch state {
        case .connecting, .connected: true
        default: false
        }
    }

    var subtitle: String { host.summary }

    var indicator: TabIndicator {
        switch state {
        case .connected: usesBlocks && shell.isRunning ? .busy : .live
        case .connecting, .idle: .busy
        case .disconnected, .failed: .down
        }
    }

    var program: RunningProgram? {
        guard state == .connected, usesBlocks else { return nil }
        let running = shell.runningBlock.flatMap { RunningProgram.resolve(command: $0.command) }
        return RunningProgram.displayed(isRunning: shell.isRunning, running: running, lastCommand: shell.blocks.last?.command)
    }

    var programActivity: CompanionActivity {
        guard state == .connected, usesBlocks else { return .inactive }
        return .outcome(running: shell.isRunning, exitCode: shell.blocks.last?.exitCode)
    }

    func connect() {
        guard !isLive else { return }
        state = .connecting
        wasBackgrounded = false
        task = Task { await run() }
    }

    func reconnect() {
        guard !isLive else { return }
        surface.feed(text: "\r\n\u{1B}[2m[reconnecting to \(host.summary)]\u{1B}[0m\r\n")
        connect()
    }

    func close() {
        task?.cancel()
        task = nil
        resolvePrompts()
        channelInput?.finish()
        endShell()
        let held = client
        client = nil
        if let held { Task { try? await held.close() } }
        state = .disconnected("Closed")
    }

    func answerCredentials(user: String, password: String, remember: Bool) {
        prompt = nil
        credentialWaiter?.resume(returning: (user, password, remember))
        credentialWaiter = nil
    }

    func answerPassphrase(_ passphrase: String, remember: Bool) {
        prompt = nil
        passphraseWaiter?.resume(returning: (passphrase, remember))
        passphraseWaiter = nil
    }

    func answerHostKey(trust: Bool) {
        prompt = nil
        hostKeyWaiter?.resume(returning: trust)
        hostKeyWaiter = nil
    }

    func cancelPrompt() {
        switch prompt {
        case .credentials:
            prompt = nil
            credentialWaiter?.resume(returning: nil)
            credentialWaiter = nil
        case .passphrase:
            prompt = nil
            passphraseWaiter?.resume(returning: nil)
            passphraseWaiter = nil
        case .trustHostKey:
            answerHostKey(trust: false)
        case .integration:
            answerIntegration(.notNow)
        default:
            prompt = nil
        }
    }

    func answerIntegration(_ choice: IntegrationChoice) {
        prompt = nil
        integrationWaiter?.resume(returning: choice)
        integrationWaiter = nil
    }

    func dismissIntegrationNotice(forever: Bool) {
        if forever { SSHHostStore.shared.decline(target) }
        integrationNotice = nil
    }

    func forgetChangedKey() {
        SSHKnownHosts.shared.forget(host: host.hostname, port: host.port ?? 22)
        prompt = nil
        state = .disconnected("Saved host key removed. Reconnect to trust the new key.")
    }

    private func resolvePrompts() {
        prompt = nil
        credentialWaiter?.resume(returning: nil)
        credentialWaiter = nil
        passphraseWaiter?.resume(returning: nil)
        passphraseWaiter = nil
        hostKeyWaiter?.resume(returning: false)
        hostKeyWaiter = nil
        integrationWaiter?.resume(returning: .notNow)
        integrationWaiter = nil
    }

    private func run() async {
        hostKeyRefused = false
        do {
            guard let plan = try await keyPlan() else {
                state = .disconnected("Cancelled")
                return
            }
            var pending = plan.identities
            var passwordNext = host.identityKeyID == nil
            let port = host.port ?? 22
            let delegate = TOFUHostKeyDelegate { [weak self] line in
                guard let self else { return false }
                let accepted = await decideHostKey(line)
                if !accepted { hostKeyRefused = true }
                return accepted
            }
            try await SSHTransport.preflight(host: host.hostname, port: port)
            var connected: SSHClient?
            while connected == nil {
                let method: SSHAuthenticationMethod
                if !pending.isEmpty {
                    switch await keyMethod(for: pending.removeFirst(), plan: plan) {
                    case .method(let found): method = found
                    case .skip: continue
                    case .cancelled:
                        state = .disconnected("Cancelled")
                        return
                    }
                } else if passwordNext {
                    passwordNext = false
                    guard let fallback = try await passwordMethod() else {
                        state = .disconnected("Cancelled")
                        return
                    }
                    method = fallback
                } else {
                    break
                }
                do {
                    connected = try await SSHClient.connect(
                        host: host.hostname,
                        port: port,
                        authenticationMethod: method,
                        hostKeyValidator: .custom(delegate),
                        reconnect: .never
                    )
                } catch {
                    if isAuthenticationFailure(error), !pending.isEmpty || passwordNext { continue }
                    throw error
                }
            }
            guard let client = connected else { throw SSHClientError.allAuthenticationOptionsFailed }
            guard !Task.isCancelled else {
                try? await client.close()
                return
            }
            self.client = client
            state = .connected
            let integrate = await prepareIntegration(client)
            guard !Task.isCancelled else { return }
            try await attach(client, integrate: integrate)
            guard !Task.isCancelled else { return }
            try? await client.close()
            if wasBackgrounded {
                finish(reason: nil)
            } else {
                finish(reason: "The session ended")
                onExit?()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            endShell()
            if hostKeyRefused {
                if case .hostKeyChanged = prompt {
                    state = .failed("Host key verification failed")
                } else {
                    state = .failed("Host key not trusted")
                }
            } else if isAuthenticationFailure(error) {
                useStoredPassword = false
                state = .failed("Authentication failed")
            } else if case .connected = state {
                finish(reason: error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
            client = nil
        }
    }

    private func finish(reason: String?) {
        client = nil
        endShell()
        let message = reason ?? (wasBackgrounded ? "The connection ended while Turm was in the background" : "The connection was closed")
        surface.feed(text: "\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n")
        state = .disconnected(message)
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if let failure = error as? SSHClientError, case .allAuthenticationOptionsFailed = failure { return true }
        return false
    }

    private func attach(_ client: SSHClient, integrate: Bool) async throws {
        var size = surface.size
        if integrate {
            let grid = blockGrid() ?? shell.size
            shell.begin(host: host.key, cols: grid.cols, rows: grid.rows)
            size = shell.size
        } else {
            shell.end()
        }
        usesBlocks = integrate
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size.cols,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        channelInput = continuation
        defer {
            continuation.finish()
            channelInput = nil
        }
        var ended = false
        lastOutput = .now
        do {
            try await client.withPTY(request) { inbound, outbound in
                // let the login banner finish first, so the echoed bootstrap line never lands inside it
                let bootstrap = Task {
                    guard integrate else { return }
                    let opened = ContinuousClock.now
                    while ContinuousClock.now - self.lastOutput < .milliseconds(250), ContinuousClock.now - opened < .seconds(3) {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try await outbound.write(ByteBuffer(bytes: Array((RemoteShellInstall.enableCommand + "\r").utf8)))
                    self.awaitHello()
                }
                defer { bootstrap.cancel() }
                let pump = Task {
                    for await event in stream {
                        do {
                            switch event {
                            case .data(let bytes):
                                try await outbound.write(ByteBuffer(bytes: bytes))
                            case .resize(let cols, let rows):
                                try await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                            }
                        } catch {
                            return
                        }
                    }
                }
                defer { pump.cancel() }
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        self.deliver(ArraySlice(buffer.readableBytesView))
                    }
                }
                ended = true
            }
        } catch {
            // Citadel closes the channel after the shell exits, which throws once the server has already closed it
            guard ended else { throw error }
        }
    }

    private func deliver(_ bytes: ArraySlice<UInt8>) {
        lastOutput = .now
        if usesBlocks, shell.phase != .inactive {
            shell.consume(bytes)
        } else {
            surface.feed(bytes)
        }
    }

    private var target: SSHTarget {
        SSHTarget(user: host.user, hostname: host.hostname, port: host.port ?? 22)
    }

    /// Probes the host and, with the user's consent, installs or updates the hooks; true when the shell should start integrated.
    private func prepareIntegration(_ client: SSHClient) async -> Bool {
        integrationNotice = nil
        integrationActivity = "Checking \(host.key) for Turm integration"
        defer { integrationActivity = nil }
        guard let result = await SSHRemoteExec.run(client, RemoteShellInstall.probeCommand, timeout: .seconds(15)),
              result.status == 0, let probe = RemoteProbe(output: result.output)
        else {
            integrationNotice = IntegrationNotice(
                text: "Could not check \(host.key) for Turm integration, so this session stays a plain terminal."
            )
            return false
        }
        if let version = probe.version {
            guard version != RemoteShellInstall.version else { return true }
            if await askIntegration(.update(shell: probe.shell)) == .install { _ = await install(client) }
            return true
        }
        let store = SSHHostStore.shared
        if store.isDeclined(target) || !store.offersIntegration { return false }
        guard RemoteShellKind.supports(probe.shell) else {
            integrationNotice = IntegrationNotice(
                text: "\(host.key) uses \(probe.shell). Turm integration supports zsh, bash and fish, so this session stays a plain terminal.",
                offersDecline: true
            )
            return false
        }
        switch await askIntegration(.install(shell: probe.shell)) {
        case .install:
            return await install(client)
        case .notNow:
            return false
        case .never:
            store.decline(target)
            return false
        }
    }

    private func askIntegration(_ offer: IntegrationOffer) async -> IntegrationChoice {
        integrationActivity = nil
        prompt = .integration(offer)
        return await withCheckedContinuation { integrationWaiter = $0 }
    }

    private func install(_ client: SSHClient) async -> Bool {
        integrationActivity = "Installing Turm integration on \(host.key)..."
        let result = await SSHRemoteExec.script(client, RemoteShellInstall.installScript(), timeout: .seconds(30))
        guard let result else {
            integrationNotice = IntegrationNotice(text: "Could not install on \(host.key): The host did not answer in time.")
            return false
        }
        guard result.status == 0 else {
            let message = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = message.isEmpty ? "Install failed with status \(result.status)." : message
            integrationNotice = IntegrationNotice(text: "Could not install on \(host.key): \(reason)")
            return false
        }
        return true
    }

    private func awaitHello() {
        helloTimer?.cancel()
        helloTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.helloWait)
            guard !Task.isCancelled else { return }
            self?.fallBackToTerminal()
        }
    }

    private func integrationStarted() {
        helloTimer?.cancel()
        helloTimer = nil
        if let grid = blockGrid() { shell.setSize(cols: grid.cols, rows: grid.rows) }
    }

    private func fallBackToTerminal() {
        guard usesBlocks, shell.phase == .starting else { return }
        let held = shell.abandon()
        usesBlocks = false
        surface.feed(held[...])
        integrationNotice = IntegrationNotice(text: "Turm integration did not start on \(host.key), so this session stays a plain terminal.")
        let size = surface.size
        channelInput?.yield(.resize(size.cols, size.rows))
    }

    private func endShell() {
        helloTimer?.cancel()
        helloTimer = nil
        gitGeneration += 1
        shell.end()
    }

    private func blockGrid() -> (cols: Int, rows: Int)? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let cell = BlockStyle.cellSize(fontSize: fontSize)
        let cols = Int(viewport.width / cell.width)
        let rows = Int(viewport.height / cell.height)
        guard cols >= 2, rows >= 2 else { return nil }
        return (cols, rows)
    }

    private func refreshGit(in path: String) {
        gitGeneration += 1
        let ticket = gitGeneration
        guard let client else {
            shell.git = nil
            return
        }
        Task { [weak self] in
            let result = await SSHRemoteExec.script(client, RemoteGit.statusScript(in: path), timeout: .seconds(5))
            guard let self, ticket == gitGeneration else { return }
            shell.git = result.flatMap { $0.status == 0 ? RemoteGit.parseStatus($0.output) : nil }
        }
    }

    /// The host's chosen key, or every stored key in OpenSSH's default order; nil when the user cancels the username prompt.
    private func keyPlan() async throws -> KeyPlan? {
        let store = SSHIdentityStore.shared
        if let keyID = host.identityKeyID {
            guard let identity = store.identity(keyID), store.privateKey(for: keyID) != nil else {
                throw SSHSessionError.missingKey
            }
            guard let user = await username() else { return nil }
            return KeyPlan(user: user, identities: [identity], explicit: true)
        }
        let identities = SSHIdentity.defaultOrder(store.identities).filter { store.privateKey(for: $0.id) != nil }
        guard !identities.isEmpty else { return KeyPlan(user: "", identities: [], explicit: false) }
        guard let user = await username() else { return nil }
        return KeyPlan(user: user, identities: identities, explicit: false)
    }

    private func keyMethod(for identity: SSHIdentity, plan: KeyPlan) async -> KeyOutcome {
        let store = SSHIdentityStore.shared
        guard let text = store.privateKey(for: identity.id) else { return .skip }
        var passphrase = store.passphrase(for: identity.id)
        while true {
            do {
                return .method(try SSHAuthentication.method(
                    username: plan.user, algorithm: identity.algorithm, privateKey: text, passphrase: passphrase
                ))
            } catch {
                guard needsPassphrase(identity, text) else { return .skip }
                let wrong = passphrase != nil
                guard let answer = await askPassphrase(for: identity, wrong: wrong) else {
                    return plan.explicit || Task.isCancelled ? .cancelled : .skip
                }
                passphrase = answer.passphrase
                if answer.remember { store.setPassphrase(answer.passphrase, for: identity.id) }
            }
        }
    }

    private func needsPassphrase(_ identity: SSHIdentity, _ text: String) -> Bool {
        guard ["ssh-ed25519", "ssh-rsa"].contains(identity.algorithm) else { return false }
        return (try? SSHIdentityStore.inspect(text))?.encrypted == true
    }

    private func askPassphrase(for identity: SSHIdentity, wrong: Bool) async -> (passphrase: String, remember: Bool)? {
        prompt = .passphrase(PassphraseRequest(keyName: identity.name, algorithm: identity.algorithm, wrong: wrong))
        return await withCheckedContinuation { passphraseWaiter = $0 }
    }

    private func passwordMethod() async throws -> SSHAuthenticationMethod? {
        if useStoredPassword, !host.user.isEmpty, let stored = SSHSecrets.shared.password(for: host) {
            return .passwordBased(username: host.user, password: stored)
        }
        guard let answer = await askCredentials(needsUsername: host.user.isEmpty, needsPassword: true) else { return nil }
        return .passwordBased(username: answer.user, password: answer.password)
    }

    private func username() async -> String? {
        if !host.user.isEmpty { return host.user }
        return await askCredentials(needsUsername: true, needsPassword: false)?.user
    }

    private func askCredentials(needsUsername: Bool, needsPassword: Bool) async -> (user: String, password: String)? {
        prompt = .credentials(CredentialRequest(needsUsername: needsUsername, needsPassword: needsPassword))
        let answer = await withCheckedContinuation { credentialWaiter = $0 }
        guard let answer else { return nil }
        let store = SSHHostStore.shared
        let stored = store.hosts.contains { $0.id == host.id }
        var updated = host
        if needsUsername { updated.user = answer.user.trimmingCharacters(in: .whitespaces) }
        if needsPassword { updated.remembersPassword = answer.remember }
        if updated != host, !stored || store.save(updated) { host = updated }
        if needsPassword { SSHSecrets.shared.set(answer.password, for: host) }
        useStoredPassword = true
        return (host.user, answer.password)
    }

    private func decideHostKey(_ line: String) async -> Bool {
        let port = host.port ?? 22
        let known = SSHKnownHosts.shared.key(host: host.hostname, port: port)
        let request = HostKeyRequest(
            host: host.hostname,
            port: port,
            algorithm: SSHKnownHosts.algorithm(ofKeyLine: line),
            fingerprint: SSHKnownHosts.fingerprint(ofKeyLine: line) ?? "unknown",
            previousFingerprint: known.flatMap(SSHKnownHosts.fingerprint(ofKeyLine:))
        )
        if let known {
            if known.split(separator: " ").prefix(2) == line.split(separator: " ").prefix(2) { return true }
            prompt = .hostKeyChanged(request)
            return false
        }
        prompt = .trustHostKey(request)
        let trusted = await withCheckedContinuation { hostKeyWaiter = $0 }
        if trusted { SSHKnownHosts.shared.trust(line, host: host.hostname, port: port) }
        return trusted
    }
}

extension SSHTerminalSession: BlockSession {
    var blocks: [MacBlock] { shell.blocks }
    var runningBlock: MacBlock? { shell.runningBlock }
    var commands: [String] { shell.commands }
    var fullScreen: TerminalSurface? { shell.fullScreen }
    var phase: CompanionPhase { shell.phase == .ready ? .ready : .running }
    var acceptsInput: Bool { state == .connected && shell.isEstablished }
    var location: String { shell.location }
    var directory: String { shell.directory }
    var branch: String? { shell.git?.branch }
    var remoteLabel: String? { nil }
    var supportsBranches: Bool { true }

    var banner: BlockSessionBanner? {
        guard state == .connected, shell.phase == .starting else { return nil }
        return .progress("Starting the shell on \(host.key)")
    }

    func submit(_ text: String) {
        shell.submit(text)
    }

    func input(_ bytes: Data) {
        shell.sendInput(Array(bytes))
    }

    func interrupt() {
        shell.interrupt()
    }

    func changeDirectory(to path: String) {
        shell.changeDirectory(to: path)
    }

    func setViewport(_ size: CGSize, fontSize: Double) {
        let sameShape = size.width == viewport.width && fontSize == self.fontSize
        let next = CGSize(width: size.width, height: sameShape ? max(size.height, viewport.height) : size.height)
        guard next != viewport || fontSize != self.fontSize else { return }
        viewport = next
        self.fontSize = fontSize
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: Self.viewportSettle)
            guard !Task.isCancelled, let self, usesBlocks, let grid = blockGrid() else { return }
            shell.setSize(cols: grid.cols, rows: grid.rows)
        }
    }

    func branches() async throws -> (names: [String], current: String?) {
        guard let client, shell.isEstablished else { throw BlockSessionError(text: "Not connected to \(host.key).") }
        let current = shell.git?.branch
        guard let result = await SSHRemoteExec.script(client, RemoteGit.branchesScript(in: shell.directory), timeout: .seconds(5)) else {
            throw BlockSessionError(text: "The host did not answer in time.")
        }
        guard result.status == 0 else { return ([], current) }
        return (RemoteGit.branches(from: result.output), current)
    }

    func switchBranch(to name: String) async throws -> String? {
        guard let client, shell.isEstablished else { throw BlockSessionError(text: "Not connected to \(host.key).") }
        let path = shell.directory
        let result = await SSHRemoteExec.script(client, RemoteGit.switchScript(to: name, in: path), timeout: .seconds(30))
        refreshGit(in: path)
        guard let result else { return "The host did not answer in time." }
        guard result.status != 0 else { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not switch to \(name)" : message
    }
}

#if targetEnvironment(simulator)
extension SSHTerminalSession {
    func showDemo(_ history: [MacBlock], home: String) {
        state = .connected
        usesBlocks = true
        shell.showDemo(history, host: host.key, home: home)
        shell.answerDemo(with: DemoMachine(user: host.user.isEmpty ? "root" : host.user, host: host.key, home: home, flavor: .bash, directory: home))
    }
}
#endif

nonisolated enum SSHSessionError: LocalizedError {
    case missingKey

    var errorDescription: String? {
        switch self {
        case .missingKey: "The key selected for this host is no longer available."
        }
    }
}
