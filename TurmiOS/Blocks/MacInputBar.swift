import SwiftUI
import TurmCore

struct MacInputBar<Session: BlockSession>: View {
    let session: Session
    let fontSize: Double
    @State private var command = ""
    @State private var recalled: Int?
    @State private var draft = ""
    @State private var focus = CommandFieldFocus()

    private var canRecallOlder: Bool {
        (recalled ?? -1) + 1 < session.commands.count
    }

    private var running: Bool {
        session.phase != .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            if running, let progress = session.runningBlock?.progress {
                BlockProgressStrip(report: progress)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !running { chips }
                HStack(spacing: 6) {
                    // the field stays mounted in both phases so the keyboard never dismisses
                    ZStack(alignment: .leading) {
                        CommandField(
                            text: $command, fontSize: fontSize, running: running, focus: focus,
                            onSubmit: send, onRecall: recall, onBytes: session.input,
                            kittyFlags: { session.runningBlock?.kittyFlags ?? 0 }
                        )
                        .frame(minHeight: 36)
                        .opacity(running ? 0 : 1)
                        .allowsHitTesting(!running)
                        if running { runningLabel }
                    }
                    if running {
                        interruptButton
                    } else {
                        circle("chevron.up", label: "Previous Command", enabled: canRecallOlder) { recall(-1) }
                        circle("chevron.down", label: "Next Command", enabled: recalled != nil) { recall(1) }
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(command.isEmpty ? Chrome.secondaryText : Chrome.onAccent)
                                .frame(width: 36, height: 36)
                                .background(command.isEmpty ? Chrome.chipFill : Chrome.accent, in: Circle())
                        }
                        .disabled(command.isEmpty)
                        .accessibilityLabel("Send")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Chrome.inputBackground.ignoresSafeArea(.container, edges: [.bottom, .horizontal]))
        .overlay(alignment: .top) { Chrome.divider.frame(height: 1) }
    }

    private var runningLabel: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Running. Keys go to the command.")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focus.activate() }
    }

    private var interruptButton: some View {
        Button {
            Haptics.warn()
            session.interrupt()
        } label: {
            Label("Interrupt", systemImage: "stop.fill")
        }
        .buttonStyle(ChromeButtonStyle(kind: .destructive, compact: true))
    }

    @ViewBuilder
    private var chips: some View {
        if !session.location.isEmpty {
            ChipFlow(spacing: 6) {
                if let remote = session.remoteLabel {
                    HostChip(host: remote)
                    staticFolder
                } else if !session.directory.isEmpty {
                    FolderChip(session: session, path: session.directory, label: session.location)
                } else {
                    staticFolder
                }
                if let branch = session.branch, session.remoteLabel == nil {
                    BranchChip(session: session, branch: branch)
                }
            }
        }
    }

    private var staticFolder: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").imageScale(.small)
            Text(session.location).lineLimit(1).truncationMode(.head)
        }
        .chipStyle()
    }

    private func circle(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(enabled ? Chrome.text : Chrome.secondaryText)
                .frame(width: 36, height: 36)
                .background(Chrome.chipFill, in: Circle())
                .overlay(Circle().stroke(Chrome.chipStroke, lineWidth: 1))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func recall(_ step: Int) {
        let history = session.commands
        if step < 0 {
            let next = (recalled ?? -1) + 1
            guard next < history.count else { return }
            if recalled == nil { draft = command }
            recalled = next
            command = history[next]
        } else {
            guard let current = recalled else { return }
            if current == 0 {
                recalled = nil
                command = draft
            } else {
                recalled = current - 1
                command = history[current - 1]
            }
        }
    }

    private func send() {
        let text = command
        guard !text.isEmpty else { return }
        command = ""
        draft = ""
        recalled = nil
        session.submit(text)
    }
}
