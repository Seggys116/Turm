import Foundation
import Observation
import SwiftTerm
import TurmCore

/// Turns the byte stream of an integrated remote shell into blocks, the way the Mac does for its own SSH sessions.
@Observable
final class SSHShell {
    enum Phase {
        case inactive
        case starting
        case ready
        case submitted
        case running
    }

    struct Remote: Equatable {
        let token: String
        let kind: RemoteShellKind
        let host: String
    }

    private static let blockLimit = 500
    private static let preludeLimit = 65_536

    private(set) var phase = Phase.inactive
    private(set) var blocks: [MacBlock] = []
    private(set) var fullScreen: TerminalSurface?
    private(set) var remote: Remote?
    private(set) var directory = ""
    var git: CompanionGit?

    @ObservationIgnored var send: ([UInt8]) -> Void = { _ in }
    @ObservationIgnored var resizeTerminal: (Int, Int) -> Void = { _, _ in }
    @ObservationIgnored var onEstablished: () -> Void = {}
    @ObservationIgnored var onPrompt: (String) -> Void = { _ in }

    @ObservationIgnored private var parser = ShellStreamParser()
    @ObservationIgnored private var hello: (token: String, kind: String, host: String)?
    @ObservationIgnored private var prelude: [UInt8] = []
    @ObservationIgnored private var fallbackHost = ""
    @ObservationIgnored private var home: String?
    @ObservationIgnored private(set) var size = (cols: 80, rows: 24)
    @ObservationIgnored private var resizedByFullScreen = false

    var isEstablished: Bool { remote != nil }
    var isRunning: Bool { phase == .running || phase == .submitted }

    var runningBlock: MacBlock? {
        blocks.last { $0.isRunning }
    }

    var commands: [String] {
        var seen = Set<String>()
        return blocks.reversed().compactMap { block in
            block.command.isEmpty || !seen.insert(block.command).inserted ? nil : block.command
        }
    }

    var location: String {
        guard !directory.isEmpty else { return "" }
        guard let home else { return directory }
        return PathDisplay.abbreviate(directory, home: home)
    }

    /// Starts listening for the hello of a freshly bootstrapped shell; earlier blocks stay as history.
    func begin(host: String, cols: Int, rows: Int) {
        end()
        parser = ShellStreamParser()
        hello = nil
        prelude = []
        remote = nil
        home = nil
        git = nil
        fallbackHost = host
        if cols >= 2, rows >= 2 { size = (cols, rows) }
        phase = .starting
    }

    /// Gives up on the integration and hands back what the shell printed so far.
    func abandon() -> [UInt8] {
        let held = prelude
        prelude = []
        phase = .inactive
        return held
    }

    func end() {
        finishCommand(exitCode: nil)
        phase = .inactive
        remote = nil
        hello = nil
        prelude = []
    }

    func consume(_ bytes: ArraySlice<UInt8>) {
        for piece in parser.consume(bytes) {
            switch piece {
            case .output(let output):
                route(output)
            case .event(.commandStarted):
                guard remote != nil, phase == .submitted else { continue }
                phase = .running
            case .event(.remoteHello(let token, let kind, let host)):
                guard remote == nil, phase == .starting else { continue }
                hello = (token, kind, host)
            case .event(.remotePrompt(let token, let exitCode, let path)):
                remotePrompt(token: token, exitCode: exitCode, directory: path)
            case .event(.promptReady), .event(.environment), .event(.notification), .event(.sshStarted):
                continue
            }
        }
    }

    func submit(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, let remote, !command.isEmpty else { return }
        let block = MacBlock(
            id: UUID(), command: command, location: location, directory: directory, git: git, host: nil,
            columns: size.cols, rows: size.rows, respond: { [weak self] reply in self?.answer(reply) }
        )
        blocks.append(block)
        trimBlocks()
        phase = .submitted
        send(remote.kind.submission.payload(for: command))
    }

    func changeDirectory(to path: String) {
        guard phase == .ready, let remote else { return }
        submit("cd " + remote.kind.quoted(path))
    }

    func sendInput(_ bytes: [UInt8]) {
        guard phase == .running, !bytes.isEmpty else { return }
        send(bytes)
    }

    func interrupt() {
        guard isRunning else { return }
        send([0x03])
    }

    func setSize(cols: Int, rows: Int) {
        guard cols >= 2, rows >= 2, cols != size.cols || rows != size.rows else { return }
        size = (cols, rows)
        runningBlock?.resize(columns: cols, rows: rows)
        if fullScreen == nil { resizeTerminal(cols, rows) }
    }

    private func remotePrompt(token: String, exitCode: Int32?, directory path: String) {
        if let remote {
            guard token == remote.token else { return }
            finishCommand(exitCode: exitCode)
        } else {
            guard phase == .starting else { return }
            let greeting = hello?.token == token ? hello : nil
            let kind = greeting.flatMap { RemoteShellKind(rawValue: $0.kind) } ?? .bash
            let host = greeting?.host ?? fallbackHost
            remote = Remote(token: token, kind: kind, host: host)
            home = path
            showGreeting(from: host)
            onEstablished()
        }
        hello = nil
        directory = path
        phase = .ready
        onPrompt(path)
    }

    private func showGreeting(from host: String) {
        let held = prelude
        prelude = []
        guard let text = RemoteShellInstall.greeting(from: held) else { return }
        let block = MacBlock(
            id: UUID(), command: "", location: "", directory: "", git: nil, host: nil,
            columns: size.cols, rows: size.rows, resumed: true
        )
        block.append(text)
        block.finish(exitCode: nil)
        block.markConnected(to: host)
        blocks.append(block)
        trimBlocks()
    }

    private func route(_ bytes: [UInt8]) {
        switch phase {
        case .starting:
            prelude.append(contentsOf: bytes)
            if prelude.count > Self.preludeLimit { prelude.removeFirst(prelude.count - Self.preludeLimit) }
        case .running:
            guard let block = runningBlock else { return }
            deliver(bytes, to: block)
        case .inactive, .ready, .submitted:
            break
        }
    }

    private func deliver(_ bytes: [UInt8], to block: MacBlock) {
        block.append(bytes)
        if !block.isAlternate {
            leaveFullScreen()
        } else if let fullScreen {
            fullScreen.feed(bytes[...])
        } else {
            enterFullScreen(replaying: bytes)
        }
    }

    private func answer(_ reply: [UInt8]) {
        guard fullScreen == nil, phase == .running else { return }
        send(reply)
    }

    private func enterFullScreen(replaying chunk: [UInt8]) {
        let surface = TerminalSurface()
        surface.view.resize(cols: size.cols, rows: size.rows)
        surface.feed(chunk[...])
        surface.onInput = { [weak self] bytes in self?.sendInput(Array(bytes)) }
        surface.onResize = { [weak self] cols, rows in
            guard let self, cols >= 2, rows >= 2 else { return }
            resizedByFullScreen = true
            resizeTerminal(cols, rows)
        }
        fullScreen = surface
    }

    private func leaveFullScreen() {
        guard fullScreen != nil else { return }
        fullScreen = nil
        guard resizedByFullScreen else { return }
        resizedByFullScreen = false
        resizeTerminal(size.cols, size.rows)
    }

    private func finishCommand(exitCode: Int32?) {
        leaveFullScreen()
        runningBlock?.finish(exitCode: exitCode)
    }

    private func trimBlocks() {
        if blocks.count > Self.blockLimit { blocks.removeFirst(blocks.count - Self.blockLimit) }
    }
}

#if targetEnvironment(simulator)
extension SSHShell {
    func showDemo(_ history: [MacBlock], host: String, home path: String) {
        blocks = history
        remote = Remote(token: "demo", kind: .bash, host: host)
        home = path
        directory = path
        phase = .ready
    }

    func answerDemo(with machine: DemoMachine) {
        send = { [weak self] bytes in
            guard let self, phase == .submitted, let token = remote?.token else { return }
            let command = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}[200~", with: "")
                .replacingOccurrences(of: "\u{1B}[201~", with: "")
                .trimmingCharacters(in: .newlines)
            let reply = machine.run(command)
            let output = reply.output.map { $0 + "\r\n" }.joined()
            let stream = "\u{1B}]7777;C\u{07}" + output + "\u{1B}]7777;R;\(token);\(reply.exitCode);\(machine.directory)\u{07}"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.consume(Array(stream.utf8)[...])
            }
        }
    }
}
#endif
