import Foundation

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
        case sourceFile(URL)

        func payload(for command: String) throws -> [UInt8] {
            switch self {
            case .bracketedPaste:
                return [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(command.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E, 0x0D]
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
    }

    static var forcedShell: String?

    private static let zshFiles: [(name: String, contents: String)] = [
        (".zshenv", """
        export TURM_INTEGRATION_DIR="$ZDOTDIR"
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        [[ -r "$_turm_home/.zshenv" ]] && source "$_turm_home/.zshenv"
        ZDOTDIR="$TURM_INTEGRATION_DIR"
        unset _turm_home

        """),
        (".zprofile", """
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        [[ -r "$_turm_home/.zprofile" ]] && source "$_turm_home/.zprofile"
        ZDOTDIR="$TURM_INTEGRATION_DIR"
        unset _turm_home

        """),
        (".zshrc", """
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        HISTFILE="$_turm_home/.zsh_history"
        [[ -r "$_turm_home/.zshrc" ]] && source "$_turm_home/.zshrc"
        if [[ -n "$TURM_USER_ZDOTDIR" ]]; then
          ZDOTDIR="$TURM_USER_ZDOTDIR"
        else
          unset ZDOTDIR
        fi
        unset _turm_home TURM_USER_ZDOTDIR TURM_INTEGRATION_DIR

        _turm_preexec() {
          _turm_ran=1
          printf '\\e]7777;C\\a'
        }
        _turm_report_env() {
          local name signature=
          for name in ${(k)parameters[(R)*export*]}; do
            case $name in
              PWD|OLDPWD|_|SHLVL) continue ;;
            esac
            signature+="$name=${(P)name}"$'\\0'
          done
          if [[ -n $_turm_env_sent && $signature == "$_turm_env_sent" ]]; then
            return
          fi
          _turm_env_sent=$signature
          local encoded
          encoded=$(command env -0 | command base64)
          encoded=${encoded//[$'\\n\\r']/}
          if (( ${#encoded} > 0 && ${#encoded} <= 262144 )); then
            printf '\\e]7777;E;%s\\a' "$encoded"
          fi
        }
        _turm_precmd() {
          local code=$?
          _turm_report_env
          if [[ -n $_turm_ran ]]; then
            printf '\\e]7777;P;%d;%s\\a' $code "$PWD"
          else
            printf '\\e]7777;P;;%s\\a' "$PWD"
          fi
          _turm_ran=
        }
        _turm_quiet() {
          PROMPT=''
          RPROMPT=''
        }
        PROMPT_EOL_MARK=''
        precmd_functions=(_turm_precmd $precmd_functions _turm_quiet)
        preexec_functions+=(_turm_preexec)
        _turm_quiet

        """),
    ]

    static func launch() throws -> Launch {
        let shell = userShell()
        let kind = Kind(path: shell) ?? .zsh
        var environment = ["TERM=xterm-256color", "COLORTERM=truecolor", "SHELL=\(shell)"] + TerminalIdentity.environment
        let inherited = ProcessInfo.processInfo.environment
        var reserved: Set<String> = ["SHELL", "TURM_CMD_FILE"]
        if kind == .zsh { reserved.insert("ZDOTDIR") }
        for (key, value) in inherited where !isTerminalIdentity(key) && !reserved.contains(key) {
            environment.append("\(key)=\(value)")
        }
        if inherited["CLICOLOR"] == nil {
            environment.append("CLICOLOR=1")
        }
        let name = (shell as NSString).lastPathComponent
        switch kind {
        case .zsh:
            let directory = try install(kind: .zsh, files: zshFiles)
            if let original = inherited["ZDOTDIR"] {
                environment.append("TURM_USER_ZDOTDIR=\(original)")
            }
            environment.append("ZDOTDIR=\(directory.path)")
            return Launch(executable: shell, execName: "-" + name, arguments: [], environment: environment, submission: .bracketedPaste)
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
                submission: .sourceFile(commandFile)
            )
        case .fish:
            let directory = try install(kind: .fish, files: [("integration.fish", ShellScripts.fish)])
            let script = directory.appendingPathComponent("integration.fish").path
            return Launch(
                executable: shell,
                execName: "-" + name,
                arguments: ["--init-command", "source \(fishQuoted(script))"],
                environment: environment,
                submission: .bracketedPaste
            )
        }
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
