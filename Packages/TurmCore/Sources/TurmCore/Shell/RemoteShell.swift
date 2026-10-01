import CryptoKit
import Foundation

public nonisolated enum RemoteShellKind: String, Equatable, Sendable {
    case zsh
    case bash
    case legacyBash = "bash-legacy"
    case fish

    public static func supports(_ shell: String) -> Bool {
        ["zsh", "bash", "fish"].contains(shell)
    }

    public var submission: ShellSubmission {
        self == .legacyBash ? .typed : .bracketedPaste
    }

    public func quoted(_ text: String) -> String {
        if self == .fish {
            return "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public nonisolated enum ShellSubmission: Equatable, Sendable {
    case bracketedPaste
    case typed

    public func payload(for command: String) -> [UInt8] {
        switch self {
        case .typed:
            return Array(command.replacingOccurrences(of: "\n", with: "\r").utf8) + [0x0D]
        case .bracketedPaste:
            return [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(command.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E, 0x0D]
        }
    }
}

public nonisolated struct RemoteProbe: Equatable, Sendable {
    public let shell: String
    public let version: String?

    public init(shell: String, version: String?) {
        self.shell = shell
        self.version = version
    }

    public init?(output: String) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let shell = lines.first, !shell.isEmpty else { return nil }
        self.shell = shell
        let version = lines.dropFirst().first ?? ""
        self.version = version.isEmpty ? nil : version
    }
}

public nonisolated enum RemoteShellInstall {
    public static let remoteDirectory = "$HOME/.turm/shell"

    public static let bootstrap = #"""
        if [ -n "$TURM_BANNER" ]; then
          unset TURM_BANNER
          if [ ! -e "$HOME/.hushlogin" ]; then
            for _turm_motd in /run/motd.dynamic /etc/motd; do [ -r "$_turm_motd" ] && cat "$_turm_motd"; done
          fi
        fi
        TURM_REMOTE="$$.$(date +%s).$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')"
        export TURM_REMOTE
        _turm_dir="$HOME/.turm/shell"
        _turm_shell=${SHELL:-/bin/sh}
        case ${_turm_shell##*/} in
          zsh)
            if [ -n "$ZDOTDIR" ]; then TURM_USER_ZDOTDIR=$ZDOTDIR; export TURM_USER_ZDOTDIR; fi
            ZDOTDIR="$_turm_dir/zsh"
            export ZDOTDIR
            exec "$_turm_shell" -l ;;
          bash)
            exec "$_turm_shell" --rcfile "$_turm_dir/rc.bash" -i ;;
          fish)
            exec "$_turm_shell" -l --init-command "source '$_turm_dir/integration.fish'" ;;
        esac
        unset TURM_REMOTE
        exec "$_turm_shell" -l

        """#

    public static let enableCommand = #" TURM_BANNER=1 exec sh "$HOME/.turm/shell/bootstrap.sh""#

    public static let probeCommand = #"sh -c 'printf "%s\n" "${SHELL##*/}"; cat "$HOME/.turm/shell/version" 2>/dev/null; exit 0'"#

    public static let uninstallCommand = #"sh -c 'rm -rf "$HOME/.turm/shell"; rmdir "$HOME/.turm" 2>/dev/null; exit 0'"#

    public static var files: [(path: String, contents: String)] {
        let files = [("bootstrap.sh", bootstrap), ("rc.bash", ShellScripts.bash), ("integration.fish", ShellScripts.fish)]
            + ShellScripts.zsh.map { ("zsh/" + $0.name, $0.contents) }
        return files.map { ($0.0, $0.1.hasSuffix("\n") ? $0.1 : $0.1 + "\n") }
    }

    public static var version: String {
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.contents.utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func installScript() -> String {
        var script = "set -e\numask 022\nd=\"\(remoteDirectory)\"\nmkdir -p \"$d/zsh\"\n"
        for (index, file) in files.enumerated() {
            let marker = "TURM_FILE_\(index)_END"
            script += "cat > \"$d/\(file.path).tmp\" <<'\(marker)'\n\(file.contents)"
            script += "\(marker)\nmv -f \"$d/\(file.path).tmp\" \"$d/\(file.path)\"\n"
        }
        script += "printf '%s\\n' '\(version)' > \"$d/version\"\n"
        return script
    }

    /// What the login shell printed before the integrated shell said hello, minus every line that shows the bootstrap command.
    public static func greeting(from prelude: [UInt8]) -> [UInt8]? {
        let marker = Array(".turm/shell/bootstrap.sh".utf8)
        var lines = prelude.split(separator: 0x0A, omittingEmptySubsequences: false)
        // the bootstrap prints the login banner itself, so only what follows its command line is kept
        if let last = lines.lastIndex(where: { $0.firstRange(of: marker) != nil }) {
            lines.removeSubrange(...last)
        }
        while let last = lines.last, !hasVisibleText(last) { lines.removeLast() }
        while let first = lines.first, !hasVisibleText(first) { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }
        return Array(lines.joined(separator: [0x0A]))
    }

    private enum Mode { case text, escape, csi, string, stringEscape }

    static func hasVisibleText(_ bytes: some Collection<UInt8>) -> Bool {
        var mode = Mode.text
        for byte in bytes {
            switch mode {
            case .text:
                if byte == 0x1B {
                    mode = .escape
                } else if byte > 0x20, byte != 0x7F {
                    return true
                }
            case .escape:
                mode = byte == 0x5B ? .csi : [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(byte) ? .string : .text
            case .csi:
                if (0x40...0x7E).contains(byte) { mode = .text }
            case .string:
                if byte == 0x07 { mode = .text } else if byte == 0x1B { mode = .stringEscape }
            case .stringEscape:
                mode = byte == 0x5C ? .text : .string
            }
        }
        return false
    }
}

public nonisolated enum RemoteGit {
    private static let prelude = "export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0\n"

    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func script(in directory: String, _ body: String) -> String {
        prelude + "cd " + quote(directory) + " 2>/dev/null || exit 3\n" + body
    }

    public static func statusScript(in directory: String) -> String {
        script(in: directory, """
            branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || exit 4
            printf '%s\\n' "$branch"
            git diff HEAD --numstat 2>/dev/null
            """)
    }

    public static func branchesScript(in directory: String) -> String {
        script(in: directory, "git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads")
    }

    public static func switchScript(to name: String, in directory: String) -> String {
        script(in: directory, "git switch " + quote(name) + " 2>&1")
    }

    public static func parseStatus(_ output: String) -> CompanionGit? {
        guard let newline = output.firstIndex(of: "\n") else {
            let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : CompanionGit(branch: name, files: 0, added: 0, removed: 0)
        }
        let name = output[..<newline].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let totals = parseNumstat(String(output[output.index(after: newline)...]))
        return CompanionGit(branch: name, files: totals.files, added: totals.added, removed: totals.removed)
    }

    public static func parseNumstat(_ text: String) -> (files: Int, added: Int, removed: Int) {
        var files = 0
        var added = 0
        var removed = 0
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            files += 1
            added += Int(columns[0]) ?? 0
            removed += Int(columns[1]) ?? 0
        }
        return (files, added, removed)
    }

    public static func branches(from output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }
}
