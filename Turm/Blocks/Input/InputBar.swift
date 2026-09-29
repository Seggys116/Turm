import SwiftUI

struct InputBar: View {
    let session: TerminalSession
    let isFocused: Bool
    @Bindable var input: InputModel
    @State private var completion = CompletionModel()
    @State private var pathMenuOpen = false
    @State private var branchMenuOpen = false

    var body: some View {
        let _ = input.draft
        VStack(alignment: .leading, spacing: 8) {
            if !input.attachments.isEmpty {
                AttachmentStrip(input: input)
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
                    onAttach: input.attach,
                    onDragTarget: { session.isDropTargeted = $0 },
                    onSelectAllBlocks: {
                        session.selection.selectAll()
                        session.selection.claimFocus()
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inputBackground.color)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
        .task { SystemCompletionEnvironment.shared.warmUp(shell: ShellIntegration.forcedShell) }
        .onDisappear { completion.close() }
        .onChange(of: session.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning, let command = session.blocks.last?.command else { return }
            SystemCompletionEnvironment.shared.commandFinished(command, directory: session.directory)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Chip(text: Block.abbreviate(session.directory), isActive: pathMenuOpen) { Image(systemName: "folder").chipIcon() }
                .onTapGesture { toggle(path: true) }
                .chipMenu(isOpen: $pathMenuOpen) {
                    PathMenu(path: session.directory) { pathMenuOpen = false }
                }
            if let git = session.git {
                Chip(text: git.branch, isActive: branchMenuOpen) { GitBranchIcon().frame(width: 12, height: 12) }
                    .onTapGesture { toggle(path: false) }
                    .chipMenu(isOpen: $branchMenuOpen) {
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
            Spacer(minLength: 0)
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

    private func submit() {
        session.submit(input.draft)
        input.reset()
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
