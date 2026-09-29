import AppKit
import SwiftTerm

final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: TerminalContainerView
    private let terminal: LocalProcessTerminalView
    private var didExit = false

    var onFocus: () -> Void = {}
    var onExit: () -> Void = {}

    override init() {
        terminal = LocalProcessTerminalView(frame: .zero)
        view = TerminalContainerView(terminal: terminal)
        super.init()
        terminal.processDelegate = self
        view.onFocus = { [weak self] in self?.onFocus() }
        startShell()
    }

    func terminate() {
        guard !didExit else { return }
        didExit = true
        terminal.terminate()
    }

    func focus() {
        guard let window = view.window, window.firstResponder !== terminal else { return }
        window.makeFirstResponder(terminal)
    }

    private func startShell() {
        let shell = Self.userShell()
        let name = "-" + (shell as NSString).lastPathComponent
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("SHELL=\(shell)")
        environment.append("TERM_PROGRAM=Turm")
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: environment,
            execName: name,
            currentDirectory: NSHomeDirectory()
        )
    }

    private static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !didExit else { return }
        didExit = true
        onExit()
    }
}

final class TerminalContainerView: NSView {
    private let terminal: NSView
    private var responderObservation: NSKeyValueObservation?
    var onFocus: () -> Void = {}

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalContainerView is created in code only")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = nil
        guard let window else { return }
        // SwiftTerm's becomeFirstResponder is not open, so watch the window instead
        responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            guard let self, window.firstResponder === self.terminal else { return }
            self.onFocus()
        }
    }
}
