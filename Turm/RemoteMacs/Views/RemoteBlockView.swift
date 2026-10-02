import AppKit
import SwiftUI
import TurmCore

struct RemoteBlockView: View {
    let block: Block
    let session: RemoteMacSession
    let selection: BlockSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !block.command.isEmpty {
                PieceText(
                    chunk: TextChunk(commandText),
                    highlights: .none,
                    piece: PieceRef(id: PieceID(blockID: block.id, target: .command), host: selection)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if block.hasOutput {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(block.segments.enumerated()), id: \.offset) { index, segment in
                        switch segment {
                        case .text(let text):
                            OutputTextView(text: text, highlights: .none, piece: pieceRef(index), cursor: block.cursor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .image(let image):
                            InlineImageView(image: image)
                        case .stack(let stack):
                            ImageStackView(stack: stack, piece: pieceRef(index))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(block.failed ? Theme.failure.color.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            if block.failed { Rectangle().fill(Theme.failure.color).frame(width: 2) }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.subtleDivider.color).frame(height: 1)
        }
        .contextMenu {
            Button("Copy Command") { copy(block.command) }
            Button("Copy Output") { copy(block.plainOutput) }
                .disabled(block.output.isEmpty)
            Button("Run Again") { session.submit(block.command) }
                .disabled(session.phase != .ready || block.command.isEmpty)
            Divider()
            Button(session.commandShortcut(for: block.command) == nil ? "Save as Command Shortcut..." : "Edit Command Shortcut...") {
                session.editor = RemoteShortcutTarget(kind: .command(block.command))
            }
            .disabled(block.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.link != .connected)
        }
    }

    private var commandText: AttributedString {
        var container = AttributeContainer()
        container.appKit.foregroundColor = TerminalPalette.textColor
        container[FontStyleKey.self] = 1
        return AttributedString(block.command, attributes: container)
    }

    private func pieceRef(_ index: Int) -> PieceRef {
        PieceRef(id: PieceID(blockID: block.id, target: .segment(index)), host: selection)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let notice = block.notice {
                Text(notice)
            } else {
                Text(block.host.map { $0 + ":" + block.directory } ?? block.directory)
            }
            if let git = block.git {
                Text("git:(\(git.branch))")
                Text("\(git.files) \u{2022} +\(git.added) -\(git.removed)")
            }
            if let code = block.exitCode, code != 0 {
                Text("exit \(code)").foregroundStyle(Theme.failure.color)
            }
            if let host = block.connectedTo {
                Text("connected to \(host)").foregroundStyle(Theme.added.color)
            } else if let duration = block.duration {
                Text("(\(Block.formatDuration(duration)))")
            } else if block.isRunning {
                Text("running")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.secondaryText.color)
        .lineLimit(1)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
