import AppKit
import Darwin
import Observation
import SwiftTerm

@Observable
final class TerminalSession: NSObject, LocalProcessDelegate {
    enum Phase {
        case starting
        case ready
        case submitted
        case running
    }

    struct RemoteShell: Equatable {
        let token: String
        let kind: RemoteShellKind
        let host: String
        let alias: String?

        var label: String { alias ?? host }
    }

    private(set) var blocks: [Block] = []
    private(set) var hasSubmittedCommand = false
    private(set) var directory = NSHomeDirectory()
    private(set) var git: GitStatus?
    private(set) var project = ProjectSnapshot.empty
    private(set) var variantChoices: [String: Int] = [:]
    private(set) var toolChoice: String?
    let runner = ActionRunner()
    private(set) var isAuxiliary: Bool
    private(set) var phase = Phase.starting
    private(set) var altScreen: AltScreenHost?
    private(set) var failure: String?
    private(set) var progress: Terminal.ProgressReport?
    private(set) var textProgress: Double?
    private(set) var seenOutcome: UUID?
    private(set) var programTitle: String?
    private(set) var runningOutputFrame: CGRect?
    private(set) var userTitle: String?
    private(set) var remotes: [RemoteShell] = []
    private(set) var connection: SSHConnection?
    private(set) var sudoOffer: UUID?
    private(set) var localDirectory: String?
    var isDropTargeted = false

    static let paneSpace = "turm.pane"

    let search = BlockSearch()
    let selection = BlockSelection()

    @ObservationIgnored var onFocus: () -> Void = {}
    @ObservationIgnored var onExit: () -> Void = {}
    @ObservationIgnored var onPopOut: (TerminalSession) -> Void = { _ in }

    @ObservationIgnored private var process: LocalProcess!
    @ObservationIgnored private var parser = ShellStreamParser()
    @ObservationIgnored private var outputProgress = OutputProgress()
    @ObservationIgnored private var didExit = false
    @ObservationIgnored private var cols = 100
    @ObservationIgnored private var sudoWatch: (block: UUID, tail: String, filled: Bool)?
    @ObservationIgnored private var rows = 30
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var gitGeneration = 0
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var isDark = true
    @ObservationIgnored private var reportsColorScheme = false
    @ObservationIgnored private var reportsFocus = false
    @ObservationIgnored private var paneFocused = false
    @ObservationIgnored private(set) var liveEnvironment: [String: String]?
    @ObservationIgnored var completionEnvironment = SystemCompletionEnvironment.shared
    @ObservationIgnored private static var liveEnvironmentApplied = false
    @ObservationIgnored private var mouseEncoding = MouseEncoding.x10
    @ObservationIgnored private var lastMotion: [UInt8]?
    @ObservationIgnored private var lastReportedFocus = false
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var submission = ShellIntegration.Submission.bracketedPaste
    @ObservationIgnored private var shellKind = ShellIntegration.Kind.zsh
    @ObservationIgnored private var pendingCommand: String?
    @ObservationIgnored private var pendingHello: (token: String, kind: String, host: String)?
    @ObservationIgnored private var reloadingToken: String?
    @ObservationIgnored private var strayOutput: [UInt8] = []
    private static let strayLimit = 8192

    init(directory: String = NSHomeDirectory(), auxiliary: Bool = false) {
        self.isAuxiliary = auxiliary
        super.init()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
            self.directory = directory
        }
        search.source = { [weak self] in
            guard let self else { return [] }
            return self.search.snapshot(self.blocks)
        }
        selection.source = { [weak self] in
            guard let self else { return [] }
            return self.search.snapshot(self.blocks)
        }
        process = LocalProcess(delegate: self)
        startShell()
        if !auxiliary { refreshProject(for: self.directory) }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocusIfChanged() }
            })
        }
    }

    deinit {
        appObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var title: String {
        if let userTitle { return userTitle }
        if let programTitle, !programTitle.isEmpty { return programTitle }
        if isRunning, let command = current?.command { return command }
        return location
    }

    var remote: RemoteShell? { remotes.last }

    var launchDirectory: String { localDirectory ?? directory }

    var isRemote: Bool { !remotes.isEmpty }

    var location: String {
        guard let label = remoteLabel else { return ShortcutStore.shared.label(for: directory) }
        return label + ":" + directory
    }

    var remoteLabel: String? {
        guard let remote else { return nil }
        if remotes.count == 1, let saved = savedRemoteHost { return saved.key }
        return remote.label
    }

    var remoteTarget: SSHTarget? {
        if remotes.count <= 1, let target = connection?.target { return target }
        guard let host = remote?.host, let at = host.lastIndex(of: "@") else { return nil }
        return SSHTarget(user: String(host[..<at]), hostname: String(host[host.index(after: at)...]), port: 22)
    }

    var remoteChannel: RemoteChannel? {
        guard remotes.count == 1, let connection, connection.integrated else { return nil }
        return connection.channel
    }

    var savedRemoteHost: SSHHost? {
        remoteTarget.flatMap(SSHHostStore.shared.host(matching:))
    }

    func rename(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        userTitle = trimmed.isEmpty ? nil : trimmed
    }

    var keyModes: KeyModes {
        let terminal = current?.emulator.terminal
        return KeyModes(
            applicationCursor: terminal?.applicationCursor ?? false,
            kittyFlags: terminal?.keyboardEnhancementFlags.rawValue ?? 0
        )
    }

    var current: Block? {
        blocks.last(where: \.isRunning)
    }

    var isRunning: Bool {
        phase == .running || phase == .submitted
    }

    var isOpen: Bool {
        !didExit && failure == nil
    }

    var activity: ShellActivity {
        if failure != nil { return .failed }
        if isRunning {
            if let progress {
                guard progress.state != .indeterminate, let value = progress.progress else { return .working }
                return .progress(Double(min(value, 100)))
            }
            return textProgress.map(ShellActivity.progress) ?? .working
        }
        guard let last = blocks.last, let exitCode = last.exitCode, last.id != seenOutcome else { return .inactive }
        return exitCode == 0 ? .succeeded : .failed
    }

    func acknowledgeOutcome() {
        runner.acknowledge()
        guard !isRunning, let last = blocks.last, last.id != seenOutcome else { return }
        seenOutcome = last.id
    }

    /// Query at close time: background and suspended jobs can outlive a command block.
    var hasRunningJobs: Bool {
        guard isOpen else { return false }
        if isRunning || phase == .starting || runner.isRunning { return true }
        guard process.shellPid > 0 else { return false }

        var capacity = 16
        while true {
            var children = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(process.shellPid, $0.baseAddress, Int32($0.count))
            }
            // If inspection fails, keep the confirmation rather than assume the shell is idle.
            guard count >= 0, errno == 0 else { return true }
            if count == capacity {
                capacity *= 2
                continue
            }
            return children.prefix(Int(count)).contains { pid in
                guard pid > 0 else { return false }
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                    return info.pbi_status != SZOMB
                }
                return kill(pid, 0) == 0 || errno != ESRCH
            }
        }
    }

    var isRunningAction: Bool {
        isOpen && runner.isRunning
    }

    var needsCloseConfirmation: Bool {
        isRunningAction || (hasSubmittedCommand && hasRunningJobs)
    }

    func terminate() {
        runner.dismiss()
        guard !didExit else { return }
        didExit = true
        process.terminate()
    }

    func focus() {
        onFocus()
    }

    var shortcuts: [Shortcut] {
        let all = Shortcuts.merged(ShortcutStore.shared.items, project: project.shortcuts)
        return isRemote ? all.filter { $0.kind == .command } : all
    }

    private var activeKind: ShellIntegration.Kind {
        remote?.kind.local ?? shellKind
    }

    func quoted(_ text: String) -> String {
        ShellIntegration.quoted(text, for: activeKind)
    }

    func submitWhenReady(_ text: String) {
        if phase == .ready {
            submit(text)
        } else {
            pendingCommand = text
        }
    }

    func submit(_ text: String) {
        submit(text, recordsHistory: true)
    }

    private func submit(_ text: String, recordsHistory: Bool) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !command.isEmpty else { return }
        let kind = activeKind
        let quote = { ShellIntegration.quoted($0, for: kind) }
        let replaced: String?
        if let route = SSHRoute.parse(command, hosts: SSHHostStore.shared.hosts) {
            replaced = route.command(remote: isRemote, quote: quote)
        } else {
            replaced = Shortcuts.expand(command, in: shortcuts, quote: quote)
        }
        let expanded = replaced ?? command
        guard let payload = try? activeSubmission(for: expanded).payload(for: expanded) else { return }
        let emulator = makeEmulator()
        let block = Block(
            command: expanded, usedShortcut: replaced != nil, directory: directory, git: git, host: remote?.label, emulator: emulator
        )
        blocks.append(block)
        hasSubmittedCommand = true
        phase = .submitted
        if !isAuxiliary, recordsHistory { CommandHistory.shared.record(command) }
        write(payload)
    }

    private func activeSubmission(for command: String) -> ShellIntegration.Submission {
        guard let remote else { return submission }
        return remote.kind == .legacyBash ? .typed : .bracketedPaste
    }

    func enableRemoteIntegration() {
        guard let connection, connection.state == .installed, !isRemote, phase == .running, altScreen == nil else { return }
        write(Array((RemoteIntegration.enableCommand + "\r").utf8))
    }

    func reloadRemoteShell() {
        guard let remote, phase == .ready else { return }
        reloadingToken = remote.token
        connection?.reloaded()
        submit(RemoteIntegration.enableCommand, recordsHistory: false)
    }

    func disconnectRemote() {
        guard isRemote, phase == .ready else { return }
        submit("exit", recordsHistory: false)
    }

    func sendInput(_ bytes: [UInt8]) {
        guard phase == .running else { return }
        if sudoOffer != nil { sudoOffer = nil }
        write(bytes)
    }

    private var sudoHost: SSHHost? {
        guard remotes.count == 1, let host = savedRemoteHost, host.sudoFill != .off else { return nil }
        return host
    }

    private func watchSudo(_ bytes: [UInt8]) {
        guard let block = current, SudoPrompt.isSudo(block.command), let host = sudoHost, let user = remoteTarget?.user else { return }
        if sudoWatch?.block != block.id { sudoWatch = (block.id, "", false) }
        guard var watch = sudoWatch, !watch.filled else { return }
        watch.tail = String((watch.tail + SSHConnection.printable(bytes)).suffix(256))
        sudoWatch = watch
        guard SudoPrompt.matches(watch.tail, user: user) else {
            if sudoOffer != nil { sudoOffer = nil }
            return
        }
        guard SSHSecrets.shared.sudoPassword(for: host) != nil else { return }
        if host.sudoFill == .automatic {
            fillSudo()
        } else if sudoOffer != block.id {
            sudoOffer = block.id
        }
    }

    func fillSudo() {
        guard phase == .running, let block = current, let watch = sudoWatch, watch.block == block.id, !watch.filled,
              let host = sudoHost, let user = remoteTarget?.user, SudoPrompt.matches(watch.tail, user: user),
              let password = SSHSecrets.shared.sudoPassword(for: host)
        else { return }
        sudoWatch?.filled = true
        sudoOffer = nil
        write(Array((password + "\r").utf8))
    }

    var mouseTracking: MouseTracking {
        guard phase == .running, altScreen == nil, let terminal = current?.emulator.terminal else { return .off }
        return MouseTracking(terminal.mouseMode)
    }

    var mouseShiftCaptured: Bool {
        current?.emulator.terminal.mouseShiftCapture ?? false
    }

    func setRunningOutputFrame(_ frame: CGRect, for block: Block) {
        guard block.isRunning, block === current, frame != runningOutputFrame else { return }
        runningOutputFrame = frame
    }

    func reportMouse(_ event: MouseEvent, scale: CGFloat) {
        let grid = MouseGrid(cols: cols, rows: rows, cellWidth: TerminalMetrics.cellWidth, cellHeight: TerminalMetrics.lineHeight, scale: scale)
        guard let bytes = MouseEncoder.encode(event, tracking: mouseTracking, encoding: mouseEncoding, grid: grid) else { return }
        if event.action == .motion {
            guard bytes != lastMotion else { return }
            lastMotion = bytes
        } else {
            lastMotion = nil
        }
        sendInput(bytes)
    }

    func pasteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let channel = remoteChannel else {
            pasteText(AttachmentStore.pasteText(for: urls))
            return
        }
        Task {
            let paths = await channel.upload(urls)
            let uploaded = urls.compactMap { paths[$0] }
            guard !uploaded.isEmpty else { return }
            pasteText(uploaded.map(PathCompleter.escape).joined(separator: " ") + " ")
        }
    }

    func pasteText(_ text: String) {
        guard phase == .running, !text.isEmpty else { return }
        let bracketed = altScreen?.view.terminal.bracketedPasteMode
            ?? current?.emulator.terminal.bracketedPasteMode
            ?? false
        var payload = Array(text.utf8)
        if bracketed {
            payload = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + payload + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        }
        write(payload)
    }

    func interrupt() {
        guard isRunning else { return }
        write([0x03])
    }

    func clearBlocks() {
        blocks.removeAll { !$0.isRunning }
    }

    func setAppearance(dark: Bool) {
        let changed = isDark != dark
        isDark = dark
        if changed, reportsColorScheme, phase == .running {
            write(TerminalReply.colorScheme(dark: dark))
        }
        current?.emulator.apply(dark: dark)
        altScreen?.apply(dark: dark)
    }

    func setPaneFocused(_ focused: Bool) {
        paneFocused = focused
        if focused, process.shellPid > 0 { SystemCompletionEnvironment.shared.setShellProcess(pid: process.shellPid) }
        if focused, let liveEnvironment { completionEnvironment.applyLiveEnvironment(liveEnvironment) }
        reportFocusIfChanged()
    }

    private func reportFocusIfChanged() {
        let focused = paneFocused && (NSApp?.isActive ?? true)
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        guard reportsFocus, phase == .running, altScreen == nil else { return }
        write(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8))
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols > 1, newRows > 1, newCols != cols || newRows != rows else { return }
        cols = newCols
        rows = newRows
        applyWindowSize()
    }

    private func applyWindowSize() {
        current?.emulator.resize(cols: cols, rows: rows)
        guard process.childfd >= 0 else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    private func write(_ bytes: [UInt8]) {
        let cleaned = ResponseFilter.rewrite(bytes, colorSchemeReporting: reportsColorScheme)
        process.send(data: cleaned[...])
    }

    private func startShell() {
        do {
            let launch = try ShellIntegration.launch()
            submission = launch.submission
            shellKind = launch.kind
            SpawnGuard.forking {
                process.startProcess(
                    executable: launch.executable,
                    args: launch.arguments,
                    environment: launch.environment,
                    execName: launch.execName,
                    currentDirectory: directory
                )
            }
            SystemCompletionEnvironment.shared.setShellProcess(pid: process.shellPid)
        } catch {
            failure = "Could not prepare the shell: \(error.localizedDescription)"
        }
    }

    private func makeEmulator() -> BlockEmulator {
        let emulator = BlockEmulator(cols: cols, rows: rows)
        emulator.apply(dark: isDark)
        // once a full-screen view owns the screen it answers terminal queries itself
        emulator.onResponse = { [weak self] data in
            guard let self, self.altScreen == nil else { return }
            self.write(Array(data))
        }
        emulator.onBufferSwitch = { [weak self] in self?.bufferSwitched() }
        emulator.onProgress = { [weak self] report in self?.progress = report }
        emulator.onTitle = { [weak self] title in self?.programTitle = title }
        return emulator
    }

    private func handle(_ piece: StreamPiece) {
        switch piece {
        case .output(let bytes):
            route(bytes)
        case .event(.notification(let title, let body)):
            Notifier.post(title: title, body: body)
        case .event(.environment(let variables)):
            guard !variables.isEmpty else { return }
            if isRemote || pendingHello != nil {
                if remotes.count <= 1 { connection?.channel.environment = variables }
                return
            }
            liveEnvironment = variables
            guard paneFocused || !Self.liveEnvironmentApplied else { return }
            Self.liveEnvironmentApplied = true
            completionEnvironment.applyLiveEnvironment(variables)
        case .event(.commandStarted):
            guard phase == .submitted else { return }
            phase = .running
            startedAt = .now
            resetProgramState()
        case .event(.promptReady(let exitCode, let path)):
            let host = remote?.label
            let hadRunning = current != nil
            endRemote()
            finishCommand(exitCode: exitCode)
            if let host, !hadRunning { appendNotice("Disconnected from \(host)", exitCode: exitCode) }
            strayOutput = []
            directory = path
            phase = .ready
            refreshGit(for: path)
            if !isAuxiliary { refreshProject(for: path) }
            runPending()
        case .event(.sshStarted(let socket, let target)):
            guard phase == .running, !isRemote, connection == nil, SSHConnection.accepts(socket: socket) else { return }
            let connection = SSHConnection(socket: socket, target: SSHTarget(identifier: target))
            self.connection = connection
            connection.start()
        case .event(.remoteHello(let token, let kind, let host)):
            guard phase == .running else { return }
            pendingHello = (token, kind, host)
        case .event(.remotePrompt(let token, let exitCode, let path)):
            remotePrompt(token: token, exitCode: exitCode, directory: path)
        }
    }

    private func runPending() {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        submit(pending)
    }

    private func remotePrompt(token: String, exitCode: Int32?, directory path: String) {
        if let index = remotes.lastIndex(where: { $0.token == token }) {
            remotes.removeSubrange(remotes.index(after: index)...)
            reloadingToken = nil
            finishCommand(exitCode: exitCode)
        } else {
            guard phase == .running, let block = current else { return }
            let hello = pendingHello?.token == token ? pendingHello : nil
            let kind = hello.flatMap { RemoteShellKind(rawValue: $0.kind) } ?? .bash
            if let reloading = reloadingToken, remotes.last?.token == reloading { remotes.removeLast() }
            reloadingToken = nil
            let alias = remotes.isEmpty ? connection?.host?.key : nil
            let host = hello?.host ?? connection?.target.map { $0.user + "@" + $0.hostname } ?? "remote"
            let shell = RemoteShell(token: token, kind: kind, host: host, alias: alias)
            if localDirectory == nil { localDirectory = directory }
            remotes.append(shell)
            connection?.markIntegrated()
            finishCommand(exitCode: nil)
            block.markConnected(to: shell.label)
        }
        pendingHello = nil
        strayOutput = []
        directory = path
        phase = .ready
        refreshRemote(for: path)
        runPending()
    }

    private func refreshRemote(for path: String) {
        gitGeneration += 1
        projectGeneration += 1
        let gitTicket = gitGeneration
        let projectTicket = projectGeneration
        guard let channel = remoteChannel else {
            git = nil
            if project != .empty { project = .empty }
            return
        }
        Task {
            let status = await channel.gitStatus(in: path)
            guard gitTicket == gitGeneration else { return }
            git = status
        }
        guard !isAuxiliary else { return }
        Task {
            let found = await channel.project(in: path)
            guard projectTicket == projectGeneration else { return }
            if found != project {
                project = found
                variantChoices = VariantStore.load(roots: found.roots, variants: found.variants)
                toolChoice = ToolChoiceStore.load(roots: found.roots)
            }
        }
    }

    private func endRemote() {
        remotes.removeAll()
        localDirectory = nil
        reloadingToken = nil
        pendingHello = nil
        connection?.stop()
        connection = nil
    }

    private func appendNotice(_ text: String, exitCode: Int32?) {
        let emulator = makeEmulator()
        let block = Block(command: "", directory: directory, git: nil, notice: text, emulator: emulator)
        if !strayOutput.isEmpty { block.append(strayOutput) }
        block.finish(exitCode: exitCode == 0 ? nil : exitCode, duration: nil)
        blocks.append(block)
    }

    private func resetProgramState() {
        reportsColorScheme = false
        reportsFocus = false
        mouseEncoding = .x10
        lastMotion = nil
        progress = nil
        outputProgress = OutputProgress()
        textProgress = nil
        programTitle = nil
    }

    private func answer(_ requests: [TerminalRequest]) {
        for request in requests {
            switch request {
            case .privateMode(2031, let enabled):
                reportsColorScheme = enabled
            case .privateMode(1004, let enabled):
                reportsFocus = enabled
            case .privateMode(let mode, let enabled):
                guard let encoding = MouseEncoding(privateMode: mode) else { break }
                if enabled {
                    mouseEncoding = encoding
                } else if mouseEncoding == encoding {
                    mouseEncoding = .x10
                }
            case .colorSchemeQuery:
                write(TerminalReply.colorScheme(dark: isDark))
            case .capabilities(let names):
                for name in names { write(TerminalReply.capability(name)) }
            }
        }
    }

    private func route(_ bytes: [UInt8]) {
        if let connection, !isRemote, let password = connection.observe(bytes) {
            process.send(data: Array((password + "\r").utf8)[...])
        }
        if isRemote, phase == .ready {
            strayOutput.append(contentsOf: bytes)
            if strayOutput.count > Self.strayLimit { strayOutput.removeFirst(strayOutput.count - Self.strayLimit) }
            return
        }
        guard phase == .running, let block = current else { return }
        if isRemote { watchSudo(bytes) }
        answer(TerminalRequestScanner.scan(bytes[...]))
        var rest = bytes[...]
        while !rest.isEmpty {
            let entering = altScreen == nil
            guard let end = AltScreenSequence.firstSwitch(in: rest, entering: entering) else {
                deliver(Array(rest), to: block)
                break
            }
            deliver(Array(rest[..<end]), to: block)
            rest = rest[end...]
            if entering {
                enterAltScreen(for: block)
            } else {
                altScreen = nil
            }
        }
        scheduleRender()
    }

    private func deliver(_ bytes: [UInt8], to block: Block) {
        block.append(bytes)
        if let altScreen {
            altScreen.feed(bytes)
        } else {
            outputProgress.feed(bytes)
            if textProgress != outputProgress.percent { textProgress = outputProgress.percent }
        }
    }

    private func bufferSwitched() {
        guard let block = current else { return }
        if block.emulator.isAlternate {
            enterAltScreen(for: block)
        } else {
            altScreen = nil
        }
    }

    private func enterAltScreen(for block: Block) {
        guard altScreen == nil else { return }
        outputProgress = OutputProgress()
        textProgress = nil
        let host = AltScreenHost(cols: cols, rows: rows)
        host.onInput = { [weak self] bytes in self?.write(bytes) }
        host.onFiles = { [weak self] urls in self?.pasteFiles(urls) }
        host.onTitle = { [weak self] title in self?.programTitle = title }
        host.onDragTarget = { [weak self] targeted in self?.isDropTargeted = targeted }
        host.onResize = { [weak self] newCols, newRows in
            guard let self else { return }
            self.cols = newCols
            self.rows = newRows
            self.applyWindowSize()
        }
        host.apply(dark: isDark)
        host.replay(block.rawBytes)
        altScreen = host
    }

    private func finishCommand(exitCode: Int32?) {
        sudoOffer = nil
        sudoWatch = nil
        altScreen = nil
        runningOutputFrame = nil
        resetProgramState()
        guard let block = current else { return }
        let elapsed = startedAt.map { ContinuousClock.now - $0 }
        block.finish(exitCode: exitCode, duration: elapsed)
        startedAt = nil
        if block.command == "clear" { clearBlocks() }
    }

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            renderPending = false
            current?.refreshOutput()
        }
    }

    func switchBranch(to name: String) async -> String? {
        let path = directory
        if let channel = remoteChannel {
            let failure = await channel.switchBranch(to: name, in: path)
            refreshRemote(for: path)
            return failure
        }
        let failure = await GitInspector.switchBranch(to: name, in: path)
        refreshGit(for: path)
        return failure
    }

    func branches() async -> [String] {
        if let channel = remoteChannel { return await channel.branches(in: directory) }
        return await GitInspector.branches(in: directory)
    }

    private func refreshProject(for path: String) {
        guard !isRemote else { return }
        projectGeneration += 1
        let generation = projectGeneration
        Task {
            let found = await ProjectDetection.detect(in: path)
            guard generation == projectGeneration else { return }
            ProjectShortcutIndex.shared.set(found.shortcuts, for: path)
            if found != project {
                project = found
                variantChoices = VariantStore.load(roots: found.roots, variants: found.variants)
                toolChoice = ToolChoiceStore.load(roots: found.roots)
            }
        }
    }

    func run(_ action: ProjectAction) {
        if !isRemote, ResolvedBar.resolve(project, preferences: .current).subShell {
            runner.start(action, command: project.commandLine(for: action, selection: variantChoices, from: action.root))
        } else {
            submit(project.commandLine(for: action, selection: variantChoices, from: directory))
        }
    }

    func cycle(_ variant: ProjectVariant) {
        let current = variantChoices[variant.id].flatMap { variant.options.indices.contains($0) ? $0 : nil } ?? variant.defaultIndex
        choose(variant, index: (current + 1) % max(variant.options.count, 1))
    }

    /// Turns the hidden action shell into an ordinary shell owned by the workspace.
    func popOutAction() {
        guard let sub = runner.release() else { return }
        onPopOut(sub)
    }

    /// Makes a former action shell behave like any other: history, project detection.
    func adopt() {
        isAuxiliary = false
        refreshProject(for: directory)
    }

    func chooseTool(_ id: String) {
        toolChoice = id
        ToolChoiceStore.save(id, roots: project.roots)
    }

    func choose(_ variant: ProjectVariant, index: Int) {
        guard variant.options.indices.contains(index) else { return }
        variantChoices[variant.id] = index
        VariantStore.save(index: index, variant: variant.id, roots: project.roots)
    }

    private func refreshGit(for path: String) {
        guard !isRemote else { return }
        gitGeneration += 1
        let generation = gitGeneration
        Task {
            let status = await GitInspector.status(in: path)
            guard generation == gitGeneration else { return }
            git = status
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !didExit else { return }
        didExit = true
        onExit()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        for piece in parser.consume(slice) {
            handle(piece)
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}
