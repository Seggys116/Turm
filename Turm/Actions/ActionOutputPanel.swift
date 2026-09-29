import SwiftUI

struct ActionOutputPanel: View {
    let runner: ActionRunner
    let session: TerminalSession
    let onPopOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalPaneView(session: session, isFocused: true)
        }
        .background(Theme.terminalBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.chipStroke.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(runner.command ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if runner.isRunning {
                headerButton("stop.fill", help: "Interrupt") { runner.stop() }
            }
            headerButton("arrow.up.forward.app", help: "Pop out into its own shell") { onPopOut() }
            headerButton("chevron.down", help: "Hide output") { runner.isWatching = false }
            headerButton("xmark", help: "Close and discard") { runner.dismiss() }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.statusBar.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }

    private var statusColor: Color {
        switch runner.progress?.outcome {
        case .succeeded: Theme.added.color
        case .failed: Theme.removed.color
        default: Color.accentColor
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
