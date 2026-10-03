import SwiftUI
import TurmCore
import UIKit

private let inset: CGFloat = 16

struct MacBlockList<Session: BlockSession>: View {
    let session: Session
    let fontSize: Double
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = BottomFollow()
    @State private var userScrolling = false
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
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(follow.following ? .bottom : .top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { old, phase, context in
            let user = Self.isUser(phase)
            guard user || Self.isUser(old) else { return }
            userScrolling = user
            apply { $0.userScrolled(to: Self.extent(context.geometry)) }
        }
        .onScrollGeometryChange(for: ScrollExtent.self, of: Self.extent) { old, new in
            if userScrolling {
                apply { $0.userScrolled(to: new) }
            } else {
                var pin = false
                apply { pin = $0.layoutChanged(from: old, to: new) }
                if pin { position.scrollTo(edge: .bottom) }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            area = CGSize(width: size.width - inset * 2, height: size.height)
            session.setViewport(area, fontSize: fontSize)
        }
        .onChange(of: fontSize) {
            session.setViewport(area, fontSize: fontSize)
        }
        .overlay(alignment: .bottomTrailing) {
            if !follow.following {
                Button {
                    Haptics.tap()
                    jump()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                        if follow.unseen { Text("New Content") }
                    }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Chrome.text)
                    .padding(.horizontal, follow.unseen ? 14 : 0)
                    .frame(minWidth: 40, minHeight: 40)
                    .background(Chrome.topBar, in: Capsule())
                    .overlay(Capsule().stroke(Chrome.chipStroke, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(ChromePressStyle())
                .accessibilityLabel(follow.unseen ? "New Content, Jump to Bottom" : "Jump to Bottom")
                .padding(12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: follow)
    }

    // the visible rect already accounts for the keyboard, the input bar inset and bottom alignment
    private static func extent(_ geometry: ScrollGeometry) -> ScrollExtent {
        ScrollExtent(top: geometry.visibleRect.minY, height: geometry.visibleRect.height, content: geometry.contentSize.height)
    }

    private static func isUser(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    private func apply(_ change: (inout BottomFollow) -> Void) {
        var next = follow
        change(&next)
        if next != follow { follow = next }
    }

    private func jump() {
        follow.jump()
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
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
