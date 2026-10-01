import SwiftUI
import TurmCore
import UIKit

private let edgeSlack: CGFloat = 48
private let inset: CGFloat = 16

struct MacBlockList<Session: BlockSession>: View {
    let session: Session
    let fontSize: Double
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var area = CGSize.zero

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.blocks) { block in
                    MacBlockRow(block: block, session: session, fontSize: fontSize)
                }
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase, context in
            guard phase == .idle else { return }
            following = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - edgeSlack
        }
        .onChange(of: session.blocks.count) {
            following = true
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: session.runningBlock?.revision) {
            if following { position.scrollTo(edge: .bottom) }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
            if following { position.scrollTo(edge: .bottom) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            area = CGSize(width: size.width - inset * 2, height: size.height)
            session.setViewport(area, fontSize: fontSize)
        }
        .onChange(of: fontSize) {
            session.setViewport(area, fontSize: fontSize)
        }
        .overlay(alignment: .bottomTrailing) {
            if !following {
                Button {
                    Haptics.tap()
                    following = true
                    withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Chrome.text)
                        .frame(width: 40, height: 40)
                        .background(Chrome.topBar, in: Circle())
                        .overlay(Circle().stroke(Chrome.chipStroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(ChromePressStyle())
                .accessibilityLabel("Jump to Bottom")
                .padding(12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: following)
    }
}

private struct MacBlockRow<Session: BlockSession>: View {
    let block: MacBlock
    let session: Session
    let fontSize: Double

    private var rerun: (() -> Void)? {
        guard session.phase == .ready, !block.command.isEmpty else { return nil }
        return { session.submit(block.command) }
    }

    private var savedShortcut: Shortcut? {
        session.commandShortcut(for: block.command)
    }

    private var saveShortcut: (title: String, run: () -> Void)? {
        guard session.supportsShortcuts, !block.command.isEmpty, block.host == nil else { return nil }
        let title = savedShortcut == nil ? "Save as Command Shortcut" : "Edit Command Shortcut"
        return (title, { session.editor = ShortcutTarget(kind: .command(block.command)) })
    }

    private var actions: BlockActions {
        BlockActions(
            copyCommand: { UIPasteboard.general.string = block.command },
            copyOutput: { UIPasteboard.general.string = block.plainOutput },
            rerun: rerun,
            shortcutTitle: saveShortcut?.title,
            shortcut: saveShortcut?.run
        )
    }

    private func menuItems() -> [ChromeMenuItem] {
        var items = [
            ChromeMenuItem(title: "Copy Command", systemImage: "terminal", isEnabled: !block.command.isEmpty) {
                actions.copyCommand()
            },
            ChromeMenuItem(title: "Copy Output", systemImage: "doc.on.doc", isEnabled: block.hasOutput) {
                actions.copyOutput()
            },
        ]
        if let rerun = actions.rerun {
            items.append(ChromeMenuItem(title: "Run Again", systemImage: "arrow.clockwise", action: rerun))
        }
        if let save = saveShortcut {
            items.append(ChromeMenuItem(title: save.title, systemImage: "at", action: save.run).separatedFromPrevious())
        }
        return items
    }

    @ViewBuilder
    var body: some View {
        if !block.command.isEmpty || block.hasOutput {
            VStack(alignment: .leading, spacing: 4) {
                header
                if !block.command.isEmpty {
                    Text(block.command)
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(BlockTheme.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if block.hasOutput {
                    OutputTextView(
                        id: block.id, text: block.output, revision: block.revision, fontSize: fontSize, actions: actions
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(block.failed ? Chrome.failure.opacity(0.07) : Color.clear)
            .overlay(alignment: .leading) {
                if block.failed { Rectangle().fill(Chrome.failure).frame(width: 2) }
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Chrome.subtleDivider).frame(height: 1)
            }
            .contentShape(Rectangle())
            .chromeContextMenu(menuItems)
        }
    }

    private var header: some View {
        ChipFlow(spacing: 6) {
            if let host = block.host {
                HostChip(host: host)
                staticFolder(block.directory.isEmpty ? block.location : block.directory)
            } else if !block.directory.isEmpty {
                FolderChip(session: session, path: block.directory, label: block.location.isEmpty ? block.directory : block.location)
            } else if !block.location.isEmpty {
                staticFolder(block.location)
            }
            if let git = block.git {
                BranchChip(session: session, branch: git.branch)
                GitStatsChip(git: git)
            }
            if let code = block.exitCode, code != 0 {
                status("exit \(code)", color: Chrome.failure)
            }
            if let target = block.connectedTo {
                status("connected to \(target)", color: Color(BlockTheme.added))
            } else if let duration = block.duration {
                status("(\(MacBlock.formatDuration(duration)))", color: Chrome.secondaryText)
            } else if block.isRunning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("running")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Chrome.secondaryText)
            }
        }
    }

    private func staticFolder(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").imageScale(.small)
            Text(text).lineLimit(1).truncationMode(.head)
        }
        .chipStyle()
    }

    private func status(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
