#if targetEnvironment(simulator)
import Foundation
import TurmCore

final class DemoMac {
    static var shared: DemoMac?

    private struct Shell {
        var summary: SessionSummary
        let machine: DemoMachine
        var running: UUID?
        var pending: String?
    }

    private static let branches = ["main", "ios", "billing-v2", "keyboard-tracking"]

    private var shells: [UUID: Shell] = [:]
    private var order: [UUID] = []
    private var fresh: Set<UUID> = []
    private var shortcuts: [Shortcut] = []
    private let deliver: (CompanionMessage) -> Void

    init(shells list: [DemoShell], deliver: @escaping (CompanionMessage) -> Void) {
        self.deliver = deliver
        for shell in list {
            let summary = shell.summary
            let git = shell.running?.git ?? shell.history.last?.git
            let machine = DemoMachine(
                user: "dev", host: DemoFixtures.macName, home: DemoFixtures.home, flavor: .zsh,
                directory: summary.directory ?? DemoFixtures.home, git: git, branches: Self.branches
            )
            shells[summary.id] = Shell(summary: summary, machine: machine, running: shell.running?.id)
            order.append(summary.id)
        }
    }

    func answer(_ message: CompanionMessage) {
        switch message {
        case .ping:
            reply([.pong])
        case .listSessions:
            reply([.sessions(summaries)])
        case .attach(let id):
            attach(id)
        case .submit(let id, let text):
            submit(text, in: id)
        case .interrupt(let id):
            interrupt(id)
        case .input(let id, let bytes):
            if bytes.contains(0x03) { interrupt(id) }
        case .create(let directory, let command):
            create(in: directory, running: command)
        case .close(let id, _):
            shells[id] = nil
            order.removeAll { $0 == id }
            reply([.sessionClosed(id: id)])
        case .listBranches(let id):
            guard let machine = shells[id]?.machine else { return }
            reply([.branches(id: id, names: machine.branchNames, current: machine.currentGit?.branch)])
        case .switchBranch(let id, let name):
            guard let machine = shells[id]?.machine else { return }
            let failure = machine.switchBranch(to: name)
            refresh(id, activity: nil)
            reply([.branchSwitched(id: id, name: name, failure: failure)] + changed(id))
        case .listShortcuts:
            reply([.shortcuts(shortcuts)])
        case .saveShortcut(let shortcut):
            shortcuts.removeAll { $0.id == shortcut.id }
            shortcuts.append(shortcut)
            reply([.ok(request: "saveShortcut"), .shortcuts(shortcuts)])
        case .removeShortcut(let id):
            shortcuts.removeAll { $0.id == id }
            reply([.ok(request: "removeShortcut"), .shortcuts(shortcuts)])
        case .directoryShortcut(let path):
            let name = (path as NSString).lastPathComponent
            let existing = shortcuts.first { $0.kind == .directory && $0.value == path }
            let draft = Shortcut(kind: .directory, key: name.lowercased(), name: name, value: path)
            reply([.directoryShortcutInfo(path: path, existing: existing, draft: draft)])
        case .commandShortcut(let command):
            let key = command.split(separator: " ").first.map(String.init) ?? command
            let existing = shortcuts.first { $0.kind == .command && $0.value == command }
            let draft = Shortcut(kind: .command, key: key, name: command, value: command)
            reply([.commandShortcutInfo(command: command, existing: existing, draft: draft)])
        case .revealInFinder:
            reply([.ok(request: "revealInFinder")])
        default:
            break
        }
    }

    private var summaries: [SessionSummary] {
        order.compactMap { shells[$0]?.summary }
    }

    private func attach(_ id: UUID) {
        guard fresh.remove(id) != nil, let shell = shells[id] else { return }
        reply([.snapshot(id: id, cols: DemoFixtures.columns, rows: DemoFixtures.rows, history: [], running: nil)])
        if let command = shell.pending {
            shells[id]?.pending = nil
            submit(command, in: id)
        }
    }

    private func create(in directory: String?, running command: String?) {
        let id = UUID()
        let machine = DemoMachine(
            user: "dev", host: DemoFixtures.macName, home: DemoFixtures.home, flavor: .zsh,
            directory: directory ?? DemoFixtures.home
        )
        let summary = SessionSummary(
            id: id, title: "zsh", location: machine.location, phase: .ready, directory: machine.directory
        )
        shells[id] = Shell(summary: summary, machine: machine, pending: command)
        order.append(id)
        fresh.insert(id)
        reply([.sessionChanged(summary)])
    }

    private func submit(_ text: String, in id: UUID) {
        guard let shell = shells[id], shell.running == nil else { return }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = shell.machine
        guard !command.isEmpty else {
            reply([.phase(id: id, phase: .ready, directory: machine.directory)])
            return
        }
        let block = UUID()
        let started = CompanionMessage.blockStarted(
            id: id, blockID: block, command: command, location: machine.location, directory: machine.directory,
            git: machine.currentGit, host: nil
        )
        let result = machine.run(command)
        var messages = [started]
        if !result.output.isEmpty {
            messages.append(.output(id: id, blockID: block, bytes: Data(result.output.joined(separator: "\r\n").utf8)))
        }
        messages.append(.blockFinished(id: id, blockID: block, exitCode: result.exitCode))
        messages.append(.phase(id: id, phase: .ready, directory: machine.directory))
        refresh(id, activity: result.exitCode == 0 ? .succeeded : .failed)
        shells[id]?.summary.program = RunningProgram.resolve(command: command)
        reply(messages + changed(id))
    }

    private func interrupt(_ id: UUID) {
        guard let shell = shells[id], let block = shell.running else { return }
        shells[id]?.running = nil
        refresh(id, activity: .failed)
        reply([
            .output(id: id, blockID: block, bytes: Data("^C".utf8)),
            .blockFinished(id: id, blockID: block, exitCode: 130),
            .phase(id: id, phase: .ready, directory: shell.machine.directory),
        ] + changed(id))
    }

    private func refresh(_ id: UUID, activity: CompanionActivity?) {
        guard let machine = shells[id]?.machine else { return }
        shells[id]?.summary.location = machine.location
        shells[id]?.summary.directory = machine.directory
        shells[id]?.summary.branch = machine.currentGit?.branch
        shells[id]?.summary.phase = .ready
        if let activity { shells[id]?.summary.activity = activity }
    }

    private func changed(_ id: UUID) -> [CompanionMessage] {
        shells[id].map { [.sessionChanged($0.summary)] } ?? []
    }

    // a short pause, as from a Mac on the network, so the running state shows before the reply lands
    private func reply(_ messages: [CompanionMessage]) {
        Task { @MainActor [deliver] in
            try? await Task.sleep(for: .milliseconds(120))
            for message in messages { deliver(message) }
        }
    }
}
#endif
