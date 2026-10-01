import Foundation
import Observation
import TurmCore

@Observable
final class SSHConnection {
    enum State: Equatable {
        case connecting
        case checking
        case offer(shell: String)
        case outdated(shell: String)
        case installing
        case installed
        case updated
        case ready
        case unsupported(shell: String)
        case failed(String)
        case dismissed
    }

    let socket: String
    let target: SSHTarget?
    let channel: RemoteChannel
    private(set) var state = State.connecting
    private(set) var integrated = false
    @ObservationIgnored private var updating = false
    @ObservationIgnored private var tail = ""
    @ObservationIgnored private var passwordSent = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: SSHHostStore
    @ObservationIgnored private let secrets: SSHSecrets

    init(socket: String, target: SSHTarget?, store: SSHHostStore = .shared, secrets: SSHSecrets = .shared) {
        self.socket = socket
        self.target = target
        channel = RemoteChannel(socket: socket)
        self.store = store
        self.secrets = secrets
    }

    static func accepts(socket: String, in directory: URL = RemoteIntegration.socketDirectory) -> Bool {
        let url = URL(fileURLWithPath: socket)
        let name = url.lastPathComponent
        return url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
            && !name.isEmpty && name.allSatisfy(\.isNumber)
    }

    var host: SSHHost? {
        target.flatMap(store.host(matching:))
    }

    var label: String {
        if let host { return host.key }
        return target.map { $0.user + "@" + $0.hostname } ?? "remote host"
    }

    var showsBanner: Bool {
        switch state {
        case .offer, .outdated, .installing, .installed, .updated, .unsupported, .failed: true
        case .connecting, .checking, .ready, .dismissed: false
        }
    }

    func start() {
        task?.cancel()
        task = Task { [weak self, socket] in
            guard await RemoteIntegration.waitForMaster(socket) else { return }
            guard let self, !Task.isCancelled else { return }
            self.state = .checking
            let probe = await RemoteIntegration.probe(socket)
            guard !Task.isCancelled else { return }
            await self.resolve(probe)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func markIntegrated() {
        integrated = true
        if case .offer = state { state = .ready }
        if state == .installed { state = .ready }
    }

    func install() {
        guard target != nil else { return }
        if case .outdated = state { updating = true }
        state = .installing
        task?.cancel()
        task = Task { [weak self, socket] in
            let failure = await RemoteIntegration.install(socket)
            guard let self, !Task.isCancelled else { return }
            self.finishInstall(failure)
        }
    }

    func decline(forever: Bool) {
        if forever, let target { store.decline(target) }
        state = .dismissed
    }

    func observe(_ bytes: [UInt8]) -> String? {
        guard !passwordSent, !integrated, let target, let host, let password = secrets.password(for: host) else { return nil }
        tail += Self.printable(bytes)
        if tail.count > 256 { tail = String(tail.suffix(256)) }
        guard SSHPasswordPrompt.matches(tail, target: target) else { return nil }
        passwordSent = true
        tail = ""
        return password
    }

    private func resolve(_ probe: RemoteProbe?) async {
        guard let target else {
            state = .dismissed
            return
        }
        guard let probe else {
            state = .dismissed
            return
        }
        if let version = probe.version {
            RemoteIntegration.markInstalled(target)
            if version != RemoteShellInstall.version {
                state = .outdated(shell: probe.shell)
            } else {
                state = integrated ? .ready : .installed
            }
            return
        }
        RemoteIntegration.removeMarker(target)
        if integrated || store.isDeclined(target) || !store.offersIntegration {
            state = .dismissed
        } else if RemoteShellKind.supports(probe.shell) {
            state = .offer(shell: probe.shell)
        } else {
            state = .unsupported(shell: probe.shell)
        }
    }

    private func finishInstall(_ failure: String?) {
        guard let target else { return }
        if let failure {
            state = .failed(failure)
            return
        }
        RemoteIntegration.markInstalled(target)
        state = integrated ? (updating ? .updated : .ready) : .installed
        updating = false
    }

    func reloaded() {
        if state == .updated { state = .ready }
    }

    static func printable(_ bytes: [UInt8]) -> String {
        enum Mode { case text, escape, csi, string, stringEscape }
        var text = ""
        var mode = Mode.text
        for byte in bytes {
            switch mode {
            case .text:
                break
            case .escape:
                mode = byte == 0x5B ? .csi : [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(byte) ? .string : .text
                continue
            case .csi:
                if (0x40...0x7E).contains(byte) { mode = .text }
                continue
            case .string:
                if byte == 0x07 { mode = .text } else if byte == 0x1B { mode = .stringEscape }
                continue
            case .stringEscape:
                mode = byte == 0x5C ? .text : .string
                continue
            }
            if byte == 0x1B {
                mode = .escape
            } else if byte == 0x0A || byte == 0x0D {
                text.append("\n")
            } else if (0x20...0x7E).contains(byte) {
                text.append(Character(UnicodeScalar(byte)))
            }
        }
        return text
    }
}
