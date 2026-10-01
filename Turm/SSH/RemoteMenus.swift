import SwiftUI
import TurmCore

struct HostMenu: View {
    let session: TerminalSession
    let close: () -> Void
    let editHost: () -> Void
    let saveShortcut: () -> Void
    var store = SSHHostStore.shared

    var body: some View {
        MenuSurface(width: 260) {
            if let saved = session.savedRemoteHost {
                MenuRow(title: "Edit SSH Host", symbol: "network", detail: saved.token, action: editHost)
                MenuRow(title: "Remove SSH Host", symbol: "trash", isDestructive: true) {
                    store.remove(saved.id)
                    close()
                }
            } else if session.remoteTarget != nil {
                MenuRow(title: "Save as SSH Host...", symbol: "network", action: editHost)
            }
            if session.remoteTarget != nil {
                MenuRow(title: "Save as Command Shortcut...", symbol: "terminal", action: saveShortcut)
            }
            MenuDivider()
            if let address = session.remoteAddress {
                MenuRow(title: "Copy Address", symbol: "doc.on.doc", detail: address) {
                    copyToPasteboard(address)
                    close()
                }
            }
            if let command = session.remoteSSHCommand {
                MenuRow(title: "Copy SSH Command", symbol: "chevron.left.forwardslash.chevron.right") {
                    copyToPasteboard(command)
                    close()
                }
            }
            MenuDivider()
            MenuRow(title: "Disconnect", symbol: "xmark.circle", isDestructive: true) {
                session.disconnectRemote()
                close()
            }
            .disabled(session.phase != .ready)
        }
    }
}

struct RemotePathMenu: View {
    let session: TerminalSession
    let close: () -> Void

    var body: some View {
        MenuSurface(width: 240) {
            MenuRow(title: "Copy Path", symbol: "doc.on.doc") {
                copyToPasteboard(session.directory)
                close()
            }
            if let address = session.remoteAddress {
                MenuRow(title: "Copy scp Path", symbol: "arrow.left.arrow.right", detail: nil) {
                    copyToPasteboard(address + ":" + session.directory)
                    close()
                }
            }
            MenuRow(title: "Copy Folder Name", symbol: "textformat") {
                copyToPasteboard((session.directory as NSString).lastPathComponent)
                close()
            }
        }
    }
}

extension TerminalSession {
    var remoteAddress: String? {
        remoteTarget.map { $0.user.isEmpty ? $0.hostname : $0.user + "@" + $0.hostname }
    }

    var remoteSSHCommand: String? {
        guard let target = remoteTarget else { return nil }
        let quote = { ShellIntegration.quoted($0, for: ShellIntegration.userKind) }
        let host = savedRemoteHost ?? SSHHostStore.shared.draft(for: target)
        return SSHRoute(token: host.key, remainder: "", host: host).command(remote: false, quote: quote)
    }

    var remoteHostDraft: SSHHost? {
        savedRemoteHost ?? remoteTarget.map(SSHHostStore.shared.draft(for:))
    }

    var remoteShortcutDraft: Shortcut? {
        guard let command = remoteSSHCommand, let host = remoteHostDraft else { return nil }
        let items = ShortcutStore.shared.items
        if let existing = items.first(where: { $0.kind == .command && $0.value == command }) { return existing }
        return Shortcut(
            kind: .command,
            key: ShortcutSuggestions.unique(Shortcuts.sanitize(host.key).lowercased(), kind: .command, in: items),
            name: "SSH to " + (remoteAddress ?? host.key),
            value: command
        )
    }
}
