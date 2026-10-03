import SwiftUI
import TurmCore

struct InputBar: View {
    let session: TerminalSession
    let isFocused: Bool
    @Bindable var input: InputModel
    @State private var completion = CompletionModel()
    @State private var pathMenuOpen = false
    @State private var branchMenuOpen = false
    @State private var shortcutEditorOpen = false
    @State private var hostMenuOpen = false
    @State private var remotePathMenuOpen = false
    @State private var hostEditorOpen = false
    @State private var hostShortcutOpen = false
    @State private var chipsFrame = CGRect.zero
    @State private var editorFrame = CGRect.zero
    @AppStorage(ShortcutSuggestionTracker.enabledKey) private var suggestionsEnabled = false
    private let tracker = ShortcutSuggestionTracker.shared

    private var suggestion: ShortcutSuggestion? {
        guard suggestionsEnabled, !session.isRunning, !session.isAuxiliary, !session.isRemote else { return nil }
        let last = session.blocks.last
        return tracker.suggestion(
            currentDirectory: session.directory,
            lastCommand: last?.usedShortcut == false ? last?.command : nil,
            shortcuts: ShortcutStore.shared.items
        )
    }

    var body: some View {
        let _ = input.draft
        VStack(alignment: .leading, spacing: 8) {
            if !input.attachments.isEmpty {
                AttachmentStrip(input: input)
            }
            if let connection = session.connection, connection.showsBanner {
                RemoteBanner(session: session, connection: connection)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let suggestion {
                SuggestionRow(suggestion: suggestion) { tracker.dismiss(suggestion) }
            }
            if completion.isOpen, !session.isRunning {
                CompletionList(model: completion)
                    .padding(.horizontal, -16)
                    .padding(.top, -2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            chips
            if session.isRunning {
                RunningInput(session: session, isFocused: isFocused)
            } else {
                InputEditor(
                    text: $input.draft,
                    isFocused: isFocused,
                    isEnabled: session.phase == .ready,
                    directory: session.directory,
                    completion: completion,
                    onSubmit: submit,
                    onClear: session.clearBlocks,
                    onFocus: session.focus,
                    onAttach: attach,
                    onDragTarget: { session.isDropTargeted = $0 },
                    onSelectAllBlocks: {
                        session.selection.selectAll()
                        session.selection.claimFocus()
                    },
                    isRemote: session.isRemote,
                    remoteChannel: session.remoteChannel,
                    tagObstacle: chipsFrame.offsetBy(dx: -editorFrame.minX, dy: -editorFrame.minY),
                    history: session.history
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }
            }
        }
        .animation(.easeOut(duration: 0.14), value: completion.isOpen)
        .animation(.easeOut(duration: 0.14), value: session.connection?.showsBanner)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inputBackground.color)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
        .task { SystemCompletionEnvironment.shared.warmUp(shell: ShellIntegration.forcedShell) }
        .onDisappear { completion.close() }
        .onAppear { recordVisit() }
        .onChange(of: session.directory) { recordVisit() }
        .onChange(of: session.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning, let block = session.blocks.last, block.host == nil else { return }
            SystemCompletionEnvironment.shared.commandFinished(block.command, directory: session.directory)
            if suggestionsEnabled, !session.isAuxiliary, !block.usedShortcut { tracker.recordCommand(block.command) }
        }
    }

    private func recordVisit() {
        guard suggestionsEnabled, !session.isAuxiliary, !session.isRemote else { return }
        tracker.recordVisit(session.directory)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let remote = session.remote {
                    remoteChips(remote)
                } else {
                    localChips
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chipsFrame = $0 }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func remoteChips(_ remote: TerminalSession.RemoteShell) -> some View {
        Chip(text: session.remoteLabel ?? remote.label, isActive: hostMenuOpen || hostEditorOpen || hostShortcutOpen) {
            Image(systemName: "network").chipIcon()
        }
            .help("Connected to \(remote.host)")
            .onTapGesture {
                remotePathMenuOpen = false
                hostMenuOpen.toggle()
            }
            .anchoredMenu(isOpen: $hostMenuOpen) {
                HostMenu(
                    session: session,
                    close: { hostMenuOpen = false },
                    editHost: {
                        hostMenuOpen = false
                        hostEditorOpen = true
                    },
                    saveShortcut: {
                        hostMenuOpen = false
                        hostShortcutOpen = true
                    }
                )
            }
            .popover(isPresented: $hostEditorOpen, arrowEdge: .top) {
                if let draft = session.remoteHostDraft {
                    SSHHostEditor(draft) { hostEditorOpen = false }
                }
            }
            .background {
                Color.clear.popover(isPresented: $hostShortcutOpen, arrowEdge: .top) {
                    if let draft = session.remoteShortcutDraft {
                        ShortcutEditor(draft) { hostShortcutOpen = false }
                    }
                }
            }
        Chip(text: session.directory, isActive: remotePathMenuOpen) {
            Image(systemName: "folder").chipIcon()
        }
            .help(session.directory)
            .onTapGesture {
                hostMenuOpen = false
                remotePathMenuOpen.toggle()
            }
            .anchoredMenu(isOpen: $remotePathMenuOpen) {
                RemotePathMenu(session: session) { remotePathMenuOpen = false }
            }
    }

    @ViewBuilder
    private var localChips: some View {
        Chip(text: ShortcutStore.shared.label(for: session.directory), isActive: pathMenuOpen || shortcutEditorOpen) {
            Image(systemName: "folder").chipIcon()
        }
            .help(Block.abbreviate(session.directory))
            .onTapGesture { toggle(path: true) }
            .anchoredMenu(isOpen: $pathMenuOpen) {
                PathMenu(path: session.directory, close: { pathMenuOpen = false }) {
                    pathMenuOpen = false
                    shortcutEditorOpen = true
                }
            }
            .popover(isPresented: $shortcutEditorOpen, arrowEdge: .top) {
                ShortcutEditor.directory(at: session.directory) { shortcutEditorOpen = false }
            }
        if let git = session.git {
            Chip(text: git.branch, isActive: branchMenuOpen) { GitBranchIcon().frame(width: 12, height: 12) }
                .onTapGesture { toggle(path: false) }
                .anchoredMenu(isOpen: $branchMenuOpen) {
                    BranchMenu(session: session) { branchMenuOpen = false }
                }
            HStack(spacing: 4) {
                Image(systemName: "doc").chipIcon()
                Text("\(git.files)")
                Text("\u{2022}").foregroundStyle(Theme.secondaryText.color)
                Text("+\(git.added)").foregroundStyle(Theme.added.color)
                Text("-\(git.removed)").foregroundStyle(Theme.removed.color)
            }
            .chipStyle()
        }
    }

    private func toggle(path: Bool) {
        if path {
            branchMenuOpen = false
            pathMenuOpen.toggle()
        } else {
            pathMenuOpen = false
            branchMenuOpen.toggle()
        }
    }

    private func attach(_ urls: [URL]) {
        guard let channel = session.remoteChannel else {
            input.attach(urls)
            return
        }
        Task {
            let paths = await channel.upload(urls)
            input.attach(urls.filter { paths[$0] != nil }, paths: paths)
        }
    }

    private func submit() {
        session.submit(input.draft)
        input.reset()
    }
}

private struct SuggestionRow: View {
    let suggestion: ShortcutSuggestion
    let onDismiss: () -> Void
    @State private var editorOpen = false

    private var message: String {
        suggestion.kind == .directory ? "You open this folder often" : "You run this often"
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: suggestion.kind.symbol).chipIcon()
                Text(message).lineLimit(1)
            }
            .chipStyle()
            .help(suggestion.value)
            Chip(text: "Save as shortcut", isActive: editorOpen) {
                Image(systemName: "plus").chipIcon()
            }
            .help("Save \(suggestion.draft.token) for \(suggestion.value)")
            .onTapGesture { editorOpen = true }
            .popover(isPresented: $editorOpen, arrowEdge: .top) {
                ShortcutEditor(suggestion.draft) { editorOpen = false }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText.color)
            .help("Dismiss suggestion")
        }
    }
}

private struct RunningInput: View {
    let session: TerminalSession
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Running. Keys go to the command; ctrl-c interrupts.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            KeyForwarder(session: session, isFocused: isFocused)
                .frame(width: 1, height: 1)
            if session.sudoOffer != nil, session.sudoOffer == session.current?.id {
                Spacer(minLength: 8)
                Button("Fill sudo password", action: session.fillSudo)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .help("Send the saved sudo password for this host (Command-Return)")
            }
        }
        .frame(minHeight: 20)
    }
}

private struct Chip<Icon: View>: View {
    let text: String
    var isActive = false
    @ViewBuilder let icon: Icon
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(text).lineLimit(1)
        }
        .chipStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isActive ? 0.22 : hovering ? 0.14 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(isActive || hovering ? 0.7 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
    }
}

private extension Image {
    func chipIcon() -> some View {
        imageScale(.small).frame(width: 12, height: 12)
    }
}

private extension View {
    func chipStyle() -> some View {
        font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.chipStroke.color, lineWidth: 1))
    }
}

private struct AttachmentStrip: View {
    let input: InputModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(input.attachments, id: \.self) { url in
                    Thumbnail(url: url) { input.remove(url) }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(width: 56, height: 56)
        .background(Theme.chipFill.color)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.text.color, Theme.inputBackground.color)
            }
            .buttonStyle(.plain)
            .padding(2)
        }
        .help(url.lastPathComponent)
        .task(id: url) {
            image = AttachmentStore.thumbnail(for: url)
        }
    }
}
