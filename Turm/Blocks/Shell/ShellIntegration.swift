import Foundation
import TurmCore

enum ShellIntegration {
    enum Kind {
        case zsh
        case bash
        case fish

        init?(path: String) {
            switch (path as NSString).lastPathComponent {
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "fish": self = .fish
            default: return nil
            }
        }
    }

    enum Submission {
        case bracketedPaste
        case typed
        case sourceFile(URL)

        func payload(for command: String) throws -> [UInt8] {
            switch self {
            case .typed:
                return ShellSubmission.typed.payload(for: command)
            case .bracketedPaste:
                return ShellSubmission.bracketedPaste.payload(for: command)
            case .sourceFile(let url):
                try Data((command + "\n").utf8).write(to: url, options: .atomic)
                return Array(" . \(ShellIntegration.quoted(url.path))\r".utf8)
            }
        }
    }

    struct Launch {
        let executable: String
        let execName: String
        let arguments: [String]
        let environment: [String]
        let submission: Submission
        let kind: Kind
    }

    static var forcedShell: String?

    static func launch() throws -> Launch {
        let shell = userShell()
        let kind = Kind(path: shell) ?? .zsh
        var environment = ["TERM=xterm-256color", "COLORTERM=truecolor", "SHELL=\(shell)"] + TerminalIdentity.environment
        let inherited = ProcessInfo.processInfo.environment
        var reserved: Set<String> = ["SHELL", "TURM_CMD_FILE", "TURM_REMOTE", "TURM_SSH_WRAPPER", "TURM_SSH_STATE", "TURM_SSH_HOSTS"]
        if kind == .zsh { reserved.insert("ZDOTDIR") }
        for (key, value) in inherited where !isTerminalIdentity(key) && !reserved.contains(key) {
            environment.append("\(key)=\(value)")
        }
        environment += RemoteIntegration.environment()
        if inherited["CLICOLOR"] == nil {
            environment.append("CLICOLOR=1")
        }
        let name = (shell as NSString).lastPathComponent
        switch kind {
        case .zsh:
            let directory = try install(kind: .zsh, files: ShellScripts.zsh)
            if let original = inherited["ZDOTDIR"] {
                environment.append("TURM_USER_ZDOTDIR=\(original)")
            }
            environment.append("ZDOTDIR=\(directory.path)")
            return Launch(executable: shell, execName: "-" + name, arguments: [], environment: environment, submission: .bracketedPaste, kind: .zsh)
        case .bash:
            let directory = try install(kind: .bash, files: [("rc.bash", ShellScripts.bash)])
            let commandFile = FileManager.default.temporaryDirectory.appendingPathComponent("turm-\(UUID().uuidString).cmd")
            environment.append("TURM_CMD_FILE=\(commandFile.path)")
            if inherited["BASH_SILENCE_DEPRECATION_WARNING"] == nil {
                environment.append("BASH_SILENCE_DEPRECATION_WARNING=1")
            }
            return Launch(
                executable: shell,
                execName: name,
                arguments: ["--rcfile", directory.appendingPathComponent("rc.bash").path, "-i"],
                environment: environment,
                submission: .sourceFile(commandFile),
                kind: .bash
            )
        case .fish:
            let directory = try install(kind: .fish, files: [("integration.fish", ShellScripts.fish)])
            let script = directory.appendingPathComponent("integration.fish").path
            return Launch(
                executable: shell,
                execName: "-" + name,
                arguments: ["--init-command", "source \(fishQuoted(script))"],
                environment: environment,
                submission: .bracketedPaste,
                kind: .fish
            )
        }
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var userKind: Kind {
        Kind(path: userShell()) ?? .zsh
    }

    static func quoted(_ text: String, for kind: Kind) -> String {
        kind == .fish ? fishQuoted(text) : quoted(text)
    }

    private static func fishQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static let identityKeys: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINAL_EMULATOR",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "STY", "TMUX", "TMUX_PANE", "__CFBundleIdentifier",
    ]
    private static let identityPrefixes = [
        "VSCODE_", "ITERM_", "KITTY_", "WEZTERM_", "ALACRITTY_", "GHOSTTY_", "WARP_", "KONSOLE_", "VTE_",
        "TERMINATOR_", "ZELLIJ", "WT_", "CURSOR_", "SHELL_SESSION_", "HERDR_", "CMUX_",
    ]

    static func isTerminalIdentity(_ key: String) -> Bool {
        identityKeys.contains(key) || identityPrefixes.contains { key.hasPrefix($0) }
    }

    private static func userShell() -> String {
        if let forced = forcedShell, Kind(path: forced) != nil, FileManager.default.isExecutableFile(atPath: forced) {
            return forced
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if Kind(path: path) != nil, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/bin/zsh"
    }

    private static func install(kind: Kind, files: [(name: String, contents: String)]) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("Turm/shell/\(kind)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            if (try? String(contentsOf: url, encoding: .utf8)) != file.contents {
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return directory
    }
}
