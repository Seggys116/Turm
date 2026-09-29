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
    private(set) var programTitle: String?
    private(set) var runningOutputFrame: CGRect?
    private(set) var userTitle: String?
    var isDropTargeted = false

    static let paneSpace = "turm.pane"

    let search = BlockSearch()
    let selection = BlockSelection()

    @ObservationIgnored var onFocus: () -> Void = {}
    @ObservationIgnored var onExit: () -> Void = {}
    @ObservationIgnored var onPopOut: (TerminalSession) -> Void = { _ in }

    @ObservationIgnored private var process: LocalProcess!
    @ObservationIgnored private var parser = ShellStreamParser()
    @ObservationIgnored private var didExit = false
    @ObservationIgnored private var cols = 100
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
        return Block.abbreviate(directory)
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

    func submit(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !command.isEmpty else { return }
        guard let payload = try? submission.payload(for: command) else { return }
        let emulator = makeEmulator()
        let block = Block(command: command, directory: directory, git: git, emulator: emulator)
        blocks.append(block)
        hasSubmittedCommand = true
        phase = .submitted
        if !isAuxiliary { CommandHistory.shared.record(command) }
        write(payload)
    }

    func sendInput(_ bytes: [UInt8]) {
        guard phase == .running else { return }
        write(bytes)
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
        pasteText(AttachmentStore.pasteText(for: urls))
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
        ResponseFilter.log(cleaned, source: altScreen == nil ? "block" : "fullscreen")
        process.send(data: cleaned[...])
    }

    private func startShell() {
        do {
            let launch = try ShellIntegration.launch()
            submission = launch.submission
            process.startProcess(
                executable: launch.executable,
                args: launch.arguments,
                environment: launch.environment,
                execName: launch.execName,
                currentDirectory: directory
            )
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
            finishCommand(exitCode: exitCode)
            directory = path
            phase = .ready
            refreshGit(for: path)
            if !isAuxiliary { refreshProject(for: path) }
        }
    }

    private func resetProgramState() {
        reportsColorScheme = false
        reportsFocus = false
        mouseEncoding = .x10
        lastMotion = nil
        progress = nil
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
        guard phase == .running, let block = current else { return }
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
        altScreen?.feed(bytes)
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
        let failure = await GitInspector.switchBranch(to: name, in: path)
        refreshGit(for: path)
        return failure
    }

    private func refreshProject(for path: String) {
        projectGeneration += 1
        let generation = projectGeneration
        Task {
            let found = await ProjectDetection.detect(in: path)
            guard generation == projectGeneration else { return }
            if found != project {
                project = found
                variantChoices = VariantStore.load(roots: found.roots, variants: found.variants)
                toolChoice = ToolChoiceStore.load(roots: found.roots)
            }
        }
    }

    func run(_ action: ProjectAction) {
        if ResolvedBar.resolve(project, preferences: .current).subShell {
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
