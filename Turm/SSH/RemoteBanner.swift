import SwiftUI

struct RemoteBanner: View {
    let session: TerminalSession
    let connection: SSHConnection

    private var message: String {
        let name = connection.label
        switch connection.state {
        case .offer(let shell):
            return "\(name) runs \(shell) without Turm integration. Install it to keep blocks, exit codes and theming over SSH."
        case .outdated:
            return "Turm integration on \(name) is older than this version of Turm. Update it to keep blocks and theming working as they should."
        case .updated:
            return "Updated Turm integration on \(name). Reload the shell to use the new hooks, or they apply from the next connection."
        case .installing:
            return "Installing Turm integration on \(name)..."
        case .installed:
            return "Turm integration is installed on \(name). New connections use it automatically."
        case .unsupported(let shell):
            return "\(name) uses \(shell). Turm integration supports zsh, bash and fish, so this session stays a plain terminal."
        case .failed(let reason):
            return "Could not install on \(name): \(reason)"
        case .connecting, .checking, .ready, .dismissed:
            return ""
        }
    }

    private var symbol: String {
        switch connection.state {
        case .failed, .unsupported: "exclamationmark.triangle"
        case .outdated: "arrow.triangle.2.circlepath"
        case .installed, .updated: "checkmark.circle"
        default: "network"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(connection.state == .installed || connection.state == .updated ? Theme.added.color : Theme.secondaryText.color)
            Text(message)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch connection.state {
            case .offer:
                button("Install", prominent: true) { connection.install() }
                button("Not now") { connection.decline(forever: false) }
                button("Never for this host") { connection.decline(forever: true) }
            case .outdated:
                button("Update", prominent: true) { connection.install() }
                button("Not now") { connection.decline(forever: false) }
            case .updated:
                if session.isRemote, session.phase == .ready {
                    button("Reload shell", prominent: true) { session.reloadRemoteShell() }
                }
                button("Dismiss") { connection.decline(forever: false) }
            case .installing:
                ProgressView().controlSize(.mini)
            case .installed:
                if session.altScreen == nil {
                    button("Use in this session", prominent: true) { session.enableRemoteIntegration() }
                }
                button("Dismiss") { connection.decline(forever: false) }
            case .unsupported:
                button("Dismiss") { connection.decline(forever: false) }
                button("Never for this host") { connection.decline(forever: true) }
            case .failed:
                button("Retry", prominent: true) { connection.install() }
                button("Dismiss") { connection.decline(forever: false) }
            case .connecting, .checking, .ready, .dismissed:
                EmptyView()
            }
        }
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(prominent ? Color.accentColor : Theme.text.color)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(prominent ? Color.accentColor.opacity(0.7) : Theme.chipStroke.color, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
