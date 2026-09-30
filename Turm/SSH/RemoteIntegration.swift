import CryptoKit
import Foundation

nonisolated enum RemoteShellKind: String, Equatable, Sendable {
    case zsh
    case bash
    case legacyBash = "bash-legacy"
    case fish

    var local: ShellIntegration.Kind {
        switch self {
        case .zsh: .zsh
        case .bash, .legacyBash: .bash
        case .fish: .fish
        }
    }

    static func supports(_ shell: String) -> Bool {
        ["zsh", "bash", "fish"].contains(shell)
    }
}

nonisolated struct RemoteProbe: Equatable, Sendable {
    let shell: String
    let version: String?

    init(shell: String, version: String?) {
        self.shell = shell
        self.version = version
    }

    init?(output: String) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let shell = lines.first, !shell.isEmpty else { return nil }
        self.shell = shell
        let version = lines.dropFirst().first ?? ""
        self.version = version.isEmpty ? nil : version
    }
}

nonisolated enum RemoteIntegration {
    static let remoteDirectory = "$HOME/.turm/shell"
    static let persistSeconds = 30

    static let bootstrap = #"""
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

    static let launchCommand = #"exec sh -c 'if [ -r "$HOME/.turm/shell/bootstrap.sh" ]; then exec sh "$HOME/.turm/shell/bootstrap.sh"; fi; exec "${SHELL:-/bin/sh}" -l'"#

    static let enableCommand = #" exec sh "$HOME/.turm/shell/bootstrap.sh""#

    static let probeCommand = #"sh -c 'printf "%s\n" "${SHELL##*/}"; cat "$HOME/.turm/shell/version" 2>/dev/null; exit 0'"#

    static let uninstallCommand = #"sh -c 'rm -rf "$HOME/.turm/shell"; rmdir "$HOME/.turm" 2>/dev/null; exit 0'"#

    static var wrapper: String {
        let boot = launchCommand.replacingOccurrences(of: "'", with: #"'\''"#)
        return #"""
            #!/bin/sh
            real=${TURM_SSH_BINARY:-ssh}
            if [ -z "$TURM_SSH_STATE" ] || [ ! -t 0 ] || [ ! -t 1 ]; then exec "$real" "$@"; fi
            interactive=1
            host=
            expect=
            endopts=
            for arg do
              if [ -n "$expect" ]; then expect=; continue; fi
              if [ -n "$host" ]; then interactive=; break; fi
              if [ -z "$endopts" ]; then
                case $arg in
                  --) endopts=1; continue ;;
                  -?*)
                    opts=${arg#-}
                    while [ -n "$opts" ]; do
                      flag=${opts%"${opts#?}"}
                      opts=${opts#?}
                      case $flag in
                        N|f|G|V|O|W|Q|T) interactive= ;;
                      esac
                      case $flag in
                        B|b|c|D|E|e|F|I|i|J|L|l|m|O|o|P|p|Q|R|S|W|w)
                          [ -z "$opts" ] && expect=1
                          opts= ;;
                      esac
                    done
                    continue ;;
                esac
              fi
              host=$arg
            done
            [ -n "$host" ] || interactive=
            [ -n "$interactive" ] || exec "$real" "$@"
            config=$("$real" -G "$@" 2>/dev/null) || exec "$real" "$@"
            user=
            hostname=
            port=
            custom=
            while IFS=' ' read -r name value; do
              case $name in
                user) [ -n "$user" ] || user=$value ;;
                hostname) [ -n "$hostname" ] || hostname=$value ;;
                port) [ -n "$port" ] || port=$value ;;
                remotecommand) custom=1 ;;
                sessiontype) [ "$value" = default ] || custom=1 ;;
                requesttty) [ "$value" = no ] && custom=1 ;;
              esac
            done <<TURM_CONFIG
            $config
            TURM_CONFIG
            [ -z "$custom" ] || exec "$real" "$@"
            target="$user@$hostname:$port"
            (umask 077; mkdir -p "$TURM_SSH_STATE") 2>/dev/null
            socket="$TURM_SSH_STATE/$$"
            printf '\033]7777;S;%s;%s\007' "$socket" "$target"
            if [ -n "$TURM_SSH_HOSTS" ] && [ -f "$TURM_SSH_HOSTS/$target" ]; then
              exec "$real" -t -o ControlMaster=auto -o "ControlPath=$socket" -o ControlPersist=\#(persistSeconds) "$@" '\#(boot)'
            fi
            exec "$real" -o ControlMaster=auto -o "ControlPath=$socket" -o ControlPersist=\#(persistSeconds) "$@"

            """#
    }

    static var remoteFiles: [(path: String, contents: String)] {
        let files = [("bootstrap.sh", bootstrap), ("rc.bash", ShellScripts.bash), ("integration.fish", ShellScripts.fish)]
            + ShellIntegration.zshFiles.map { ("zsh/" + $0.name, $0.contents) }
        return files.map { ($0.0, $0.1.hasSuffix("\n") ? $0.1 : $0.1 + "\n") }
    }

    static var version: String {
        var hasher = SHA256()
        for file in remoteFiles {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.contents.utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func installScript() -> String {
        var script = "set -e\numask 022\nd=\"\(remoteDirectory)\"\nmkdir -p \"$d/zsh\"\n"
        for (index, file) in remoteFiles.enumerated() {
            let marker = "TURM_FILE_\(index)_END"
            script += "cat > \"$d/\(file.path).tmp\" <<'\(marker)'\n\(file.contents)"
            script += "\(marker)\nmv -f \"$d/\(file.path).tmp\" \"$d/\(file.path)\"\n"
        }
        script += "printf '%s\\n' '\(version)' > \"$d/version\"\n"
        return script
    }

    static var socketDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("turm-ssh", isDirectory: true)
    }

    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Turm/ssh", isDirectory: true)
    }

    static var hostsDirectory: URL {
        supportDirectory.appendingPathComponent("hosts", isDirectory: true)
    }

    static var wrapperURL: URL {
        supportDirectory.appendingPathComponent("turm-ssh")
    }

    static func environment() -> [String] {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
            let url = wrapperURL
            let contents = wrapper
            if (try? String(contentsOf: url, encoding: .utf8)) != contents {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return []
        }
        return [
            "TURM_SSH_WRAPPER=\(wrapperURL.path)",
            "TURM_SSH_STATE=\(socketDirectory.path)",
            "TURM_SSH_HOSTS=\(hostsDirectory.path)",
        ]
    }

    static func isInstalled(_ target: SSHTarget) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: target).path)
    }

    static func markInstalled(_ target: SSHTarget) {
        try? FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
        try? Data((version + "\n").utf8).write(to: marker(for: target), options: .atomic)
    }

    static func removeMarker(_ target: SSHTarget) {
        try? FileManager.default.removeItem(at: marker(for: target))
    }

    static func installedTargets() -> [SSHTarget] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hostsDirectory.path)) ?? []
        return names.sorted().compactMap(SSHTarget.init(identifier:))
    }

    private static func marker(for target: SSHTarget) -> URL {
        hostsDirectory.appendingPathComponent(target.identifier.replacingOccurrences(of: "/", with: "_"))
    }

    @concurrent
    static func waitForMaster(_ socket: String, timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if FileManager.default.fileExists(atPath: socket),
               let result = SSHProcess.run(RemoteChannel.multiplexed(socket) + ["-O", "check", "turm"], timeout: 5), result.status == 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    @concurrent
    static func probe(_ socket: String) async -> RemoteProbe? {
        guard let result = RemoteChannel.session(on: socket, ["-T", "turm", probeCommand], timeout: 15), result.status == 0 else { return nil }
        return RemoteProbe(output: result.output)
    }

    @concurrent
    static func install(_ socket: String) async -> String? {
        let script = Data(installScript().utf8)
        guard let result = RemoteChannel.session(on: socket, ["-T", "turm", "sh -s"], input: script, timeout: 30) else {
            return "The host did not answer in time."
        }
        guard result.status == 0 else {
            let message = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Install failed with status \(result.status)." : message
        }
        return nil
    }

    @concurrent
    static func uninstall(_ target: SSHTarget) async -> String? {
        let arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlPath=none", "-T",
            "-p", String(target.port), "-l", target.user, target.hostname, uninstallCommand,
        ]
        guard let result = SSHProcess.run(arguments, timeout: 20) else { return "The host did not answer in time." }
        guard result.status == 0 else {
            let message = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "ssh exited with status \(result.status)." : message
        }
        return nil
    }
}
