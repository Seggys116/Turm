import AppKit
import SwiftUI
import TurmCore
import UniformTypeIdentifiers

struct FileSidebar: View {
    let session: TerminalSession
    @State private var root = ""
    @State private var listing = ListedDirectory(path: "", entries: [])
    @State private var children: [String: ListedDirectory] = [:]
    @State private var expanded: Set<String> = []
    @State private var filter = ""
    @State private var includeHidden = false
    @State private var targeted: String?
    @State private var dropError: String?
    @State private var dropClaimed = false
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var menuPath: String?
    @FocusState private var renameFocused: Bool
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterField
            contents
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: session.directory, initial: true) { _, path in
            root = path
            expanded = []
            children = [:]
            reloadRoot()
        }
        .onChange(of: session.connection?.integrated) { _, _ in
            reloadRoot()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(PathDisplay.abbreviate(root))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                includeHidden.toggle()
            } label: {
                Image(systemName: includeHidden ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText.color)
            .help(includeHidden ? "Hide hidden files" : "Show hidden files")
            PaneCloseButton(help: "Hide Files") { session.showsFiles = false }
        }
        .padding(.horizontal, ChromeMetrics.sidebarHorizontalPadding)
        .padding(.vertical, 10)
        .modifier(DirectoryDrop(directory: root, receive: { providers, folder in
            receive(providers, into: folder)
        }))
    }

    private var filterField: some View {
        TextField("Filter", text: $filter)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
                    .stroke(Theme.chipStroke.color, lineWidth: 1)
            )
            .padding(.horizontal, ChromeMetrics.sidebarHorizontalPadding)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var contents: some View {
        if let failure = listing.failure {
            Text(failure)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flat) { item in
                        row(item.entry, depth: item.depth)
                        if item.entry.isDirectory, expanded.contains(item.entry.path), let failure = children[item.entry.path]?.failure {
                            Text(failure)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText.color)
                                .padding(.leading, 8 + CGFloat(item.depth + 1) * 14)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .squareScrollbar(overlays: true)
            .modifier(DirectoryDrop(directory: root, receive: { providers, folder in
                receive(providers, into: folder)
            }))
            if let dropError {
                Text(dropError)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.failure.color)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    private struct FlatRow: Identifiable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    private var flat: [FlatRow] {
        var result: [FlatRow] = []
        func walk(_ entries: [FileEntry], depth: Int) {
            for entry in FileListing.present(entries, includeHidden: includeHidden, filter: filter) {
                result.append(FlatRow(entry: entry, depth: depth))
                guard entry.isDirectory, expanded.contains(entry.path), let listed = children[entry.path], listed.failure == nil else { continue }
                walk(listed.entries, depth: depth + 1)
            }
        }
        walk(listing.entries, depth: 0)
        return result
    }

    @ViewBuilder
    private func row(_ entry: FileEntry, depth: Int) -> some View {
        let open = expanded.contains(entry.path)
        HStack(spacing: 4) {
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText.color)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }
            FileTypeIcon(name: entry.name, isDirectory: entry.isDirectory)
            if renaming == entry.path {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($renameFocused)
                    .onSubmit { commitRename(entry) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, ChromeMetrics.sidebarHorizontalPadding + CGFloat(depth) * 14)
        .padding(.trailing, ChromeMetrics.sidebarHorizontalPadding)
        .frame(minHeight: ChromeMetrics.rowHeight)
        .onOutsideFieldClick(isActive: renaming == entry.path) { commitRename(entry) }
        .background(targeted == entry.path ? Theme.dropFill.color : Color.clear)
        .contentShape(Rectangle())
        .overlay {
            if renaming != entry.path {
                FileRowClicks(
                    isDirectory: entry.isDirectory,
                    path: entry.path,
                    onToggle: { toggle(entry.path) },
                    onOpen: { openFile(entry) },
                    onDrop: { providers in
                        guard entry.isDirectory else { return false }
                        receive(providers, into: entry.path, fromRow: true)
                        return true
                    },
                    onTarget: { isTargeted in
                        if isTargeted { targeted = entry.path } else if targeted == entry.path { targeted = nil }
                    }
                )
            }
        }
        .pointerMenu(isOpen: Binding(
            get: { menuPath == entry.path },
            set: { menuPath = $0 ? entry.path : (menuPath == entry.path ? nil : menuPath) }
        )) {
            rowMenu(entry)
        }
        .help(entry.isDirectory ? "Folder" : entry.kind)
    }

    private func rowMenu(_ entry: FileEntry) -> some View {
        MenuSurface(width: 220) {
            if !entry.isDirectory {
                MenuRow(title: "Open", symbol: "doc.text") {
                    menuPath = nil
                    openFile(entry)
                }
            }
            MenuRow(title: "Rename", symbol: "pencil") {
                menuPath = nil
                beginRename(entry)
            }
            MenuDivider()
            MenuRow(title: "Copy Local Path", symbol: "doc.on.doc") {
                copyToPasteboard(localPath(entry))
                menuPath = nil
            }
            MenuRow(title: "Copy Full Path", symbol: "doc.on.doc") {
                copyToPasteboard(entry.path)
                menuPath = nil
            }
            if session.isRemote, let address = session.remoteAddress {
                MenuRow(title: "Copy scp Path", symbol: "arrow.left.arrow.right") {
                    copyToPasteboard(address + ":" + entry.path)
                    menuPath = nil
                }
            }
            MenuDivider()
            if session.isRemote {
                MenuRow(title: "Delete", symbol: "trash", isDestructive: true) {
                    menuPath = nil
                    deleteRemote(entry)
                }
            } else {
                MenuRow(title: "Show in Finder", symbol: "folder") {
                    menuPath = nil
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                MenuRow(title: "Move to Trash", symbol: "trash", isDestructive: true) {
                    menuPath = nil
                    trash(entry)
                }
            }
        }
    }

    private func localPath(_ entry: FileEntry) -> String {
        let root = session.directory
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if entry.path.hasPrefix(prefix) { return String(entry.path.dropFirst(prefix.count)) }
        return (entry.path as NSString).lastPathComponent
    }

    private func openFile(_ entry: FileEntry) {
        if session.isRemote {
            workspace?.openRemoteFile(entry.path, from: session)
        } else {
            workspace?.openFile(entry.path)
        }
    }

    private func beginRename(_ entry: FileEntry) {
        renameDraft = entry.name
        renaming = entry.path
        renameFocused = true
    }

    private func commitRename(_ entry: FileEntry) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != entry.name, !name.contains("/") && !name.contains("\0") else { return }
        let destination = URL(fileURLWithPath: entry.path).deletingLastPathComponent().appendingPathComponent(name)
        if let channel = session.remoteChannel {
            let from = RemoteChannel.quote(entry.path)
            let to = RemoteChannel.quote(destination.path)
            Task {
                let result = await Task.detached { channel.run("mv -n \(from) \(to)") }.value
                guard result?.status == 0 else {
                    dropError = "Could not rename \(entry.name)."
                    return
                }
                expanded.remove(entry.path)
                children[entry.path] = nil
                reloadVisible()
            }
            return
        }
        if session.isRemote {
            dropError = "The remote shell is not connected."
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            dropError = "\(name) already exists"
            return
        }
        do {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: entry.path), to: destination)
            expanded.remove(entry.path)
            children[entry.path] = nil
            reloadVisible()
        } catch {
            dropError = error.localizedDescription
        }
    }

    private func deleteRemote(_ entry: FileEntry) {
        guard let channel = session.remoteChannel else {
            dropError = "The remote shell is not connected."
            return
        }
        let path = entry.path
        Task {
            let failure = await Task.detached { channel.delete(path) }.value
            if let failure {
                dropError = failure
                return
            }
            expanded.remove(path)
            children[path] = nil
            reloadVisible()
        }
    }

    private func trash(_ entry: FileEntry) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            expanded.remove(entry.path)
            children[entry.path] = nil
            reloadVisible()
        } catch {
            dropError = error.localizedDescription
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            return
        }
        expanded.insert(path)
        guard children[path] == nil else { return }
        load(path)
    }

    private func reloadRoot() {
        let path = root
        dropError = nil
        let channel = session.remoteChannel
        let remote = session.isRemote
        Task {
            let listed: ListedDirectory
            if let channel {
                listed = await Task.detached { channel.listDirectory(path) }.value
            } else if remote {
                listed = ListedDirectory(path: path, entries: [], failure: "The remote shell is not connected.")
            } else {
                listed = await Task.detached { LocalDirectory.list(path) }.value
            }
            guard root == path else { return }
            listing = listed
        }
    }

    private func load(_ path: String) {
        let channel = session.remoteChannel
        let remote = session.isRemote
        Task {
            let listed: ListedDirectory
            if let channel {
                listed = await Task.detached { channel.listDirectory(path) }.value
            } else if remote {
                listed = ListedDirectory(path: path, entries: [], failure: "The remote shell is not connected.")
            } else {
                listed = await Task.detached { LocalDirectory.list(path) }.value
            }
            guard expanded.contains(path), root == session.directory else { return }
            children[path] = listed
        }
    }

    private func reloadVisible() {
        reloadRoot()
        for path in expanded { load(path) }
    }

    private func receive(_ providers: [NSItemProvider], into folder: String, fromRow: Bool = false) {
        if fromRow {
            dropClaimed = true
            perform(providers, into: folder)
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard !dropClaimed else {
                dropClaimed = false
                return
            }
            perform(providers, into: folder)
        }
    }

    private func perform(_ providers: [NSItemProvider], into folder: String) {
        if let channel = session.remoteChannel {
            Task {
                let message = await FileSidebarDrop.send(providers, into: folder, channel: channel)
                reloadVisible()
                dropError = message
            }
            return
        }
        if session.isRemote {
            dropError = "The remote shell is not connected."
            return
        }
        Task {
            let message = await FileSidebarDrop.receive(providers, into: folder)
            reloadVisible()
            dropError = message
        }
    }
}

private struct DirectoryDrop: ViewModifier {
    let directory: String
    let receive: ([NSItemProvider], String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    Rectangle()
                        .fill(Theme.dropFill.color)
                        .overlay(Rectangle().strokeBorder(Theme.dropOutline.color, lineWidth: 1))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, UTType(importedAs: FileDrop.moveType)], isTargeted: $targeted) { providers in
                guard !directory.isEmpty else { return false }
                receive(providers, directory)
                return true
            }
    }
}

private struct FileTypeIcon: View {
    let name: String
    let isDirectory: Bool

    var body: some View {
        let mark = Self.mark(name: name, isDirectory: isDirectory)
        Glyph(symbol: mark.symbol, fallback: mark.fallback, size: 14)
            .foregroundStyle(Theme.text.color)
            .frame(width: 16, height: 16)
    }

    private static func mark(name: String, isDirectory: Bool) -> (symbol: String, fallback: String) {
        if isDirectory { return ("folder.fill", "folder.fill") }
        let ext = (name as NSString).pathExtension.lowercased()
        return switch ext {
        case "py", "pyi", "ipynb": ("brand:python", "chevron.left.forwardslash.chevron.right")
        case "js", "mjs", "cjs", "jsx": ("brand:nodejs", "curlybraces")
        case "ts", "tsx": ("brand:typescript", "curlybraces")
        case "swift": ("brand:swift", "swift")
        case "go": ("brand:go", "chevron.left.forwardslash.chevron.right")
        case "rs": ("brand:rust", "hammer")
        case "rb": ("brand:rubyonrails", "diamond")
        case "java", "kt": ("brand:openjdk", "chevron.left.forwardslash.chevron.right")
        case "dart": ("brand:dart", "scope")
        case "json": ("curlybraces", "curlybraces")
        case "md", "markdown": ("doc.richtext", "doc.richtext")
        case "html", "htm": ("chevron.left.forwardslash.chevron.right", "chevron.left.forwardslash.chevron.right")
        case "css", "scss": ("paintbrush", "paintbrush")
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": ("photo", "photo")
        case "sh", "bash", "zsh": ("terminal", "terminal")
        case "yml", "yaml", "toml": ("list.bullet", "list.bullet")
        case "lock": ("lock", "lock")
        case "pdf": ("doc.richtext", "doc.richtext")
        case "zip", "gz", "tar": ("doc.zipper", "doc.zipper")
        default: ("doc.text", "doc.text")
        }
    }
}

private struct FileRowClicks: NSViewRepresentable {
    var isDirectory: Bool
    var path: String
    var onToggle: () -> Void
    var onOpen: () -> Void
    var onDrop: ([NSItemProvider]) -> Bool
    var onTarget: (Bool) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.isDirectory = isDirectory
        view.path = path
        view.onToggle = onToggle
        view.onOpen = onOpen
        view.onDrop = onDrop
        view.onTarget = onTarget
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.isDirectory = isDirectory
        view.path = path
        view.onToggle = onToggle
        view.onOpen = onOpen
        view.onDrop = onDrop
        view.onTarget = onTarget
    }

    final class ClickView: NSView, NSDraggingSource {
        var isDirectory = false
        var path = ""
        var onToggle: () -> Void = {}
        var onOpen: () -> Void = {}
        var onDrop: ([NSItemProvider]) -> Bool = { _ in false }
        var onTarget: (Bool) -> Void = { _ in }
        private var start: NSPoint?
        private var didDrag = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(FileDrop.moveType)])
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                if !isDirectory { onOpen() }
                start = nil
                return
            }
            start = event.locationInWindow
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, !didDrag else { return }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard hypot(dx, dy) >= 4 else { return }
            didDrag = true
            let writer = NSPasteboardItem()
            let url = URL(fileURLWithPath: path)
            writer.setString(url.absoluteString, forType: .fileURL)
            writer.setData(Data(path.utf8), forType: NSPasteboard.PasteboardType(FileDrop.moveType))
            let item = NSDraggingItem(pasteboardWriter: writer)
            let local = convert(event.locationInWindow, from: nil)
            item.draggingFrame = NSRect(x: local.x - 12, y: local.y - 12, width: 24, height: 24)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if !didDrag, event.clickCount < 2, isDirectory { onToggle() }
            start = nil
            didDrag = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : [.copy, .move]
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender) else { return [] }
            onTarget(true)
            return operation(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender) else { return [] }
            return operation(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTarget(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTarget(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTarget(false)
            let providers = Self.providers(from: sender)
            guard !providers.isEmpty else { return false }
            return onDrop(providers)
        }

        private func accepts(_ sender: NSDraggingInfo) -> Bool {
            guard isDirectory, let types = sender.draggingPasteboard.types else { return false }
            return types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType(FileDrop.moveType))
        }

        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            let move = sender.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType(FileDrop.moveType)) == true
            return move ? .move : .copy
        }

        private static func providers(from info: NSDraggingInfo) -> [NSItemProvider] {
            guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
            return items.compactMap { item in
                let provider = NSItemProvider()
                var wrote = false
                if let data = item.data(forType: NSPasteboard.PasteboardType(FileDrop.moveType)) {
                    provider.registerDataRepresentation(forTypeIdentifier: FileDrop.moveType, visibility: .all) { completion in
                        completion(data, nil)
                        return nil
                    }
                    wrote = true
                }
                if let text = item.string(forType: .fileURL) {
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                        completion(Data(text.utf8), nil)
                        return nil
                    }
                    wrote = true
                }
                return wrote ? provider : nil
            }
        }
    }
}

enum FileSidebarDrop {
    static func receive(_ providers: [NSItemProvider], into directory: String) async -> String? {
        var moves: [String] = []
        for provider in providers {
            if let path = await movePath(from: provider) { moves.append(path) }
        }
        if !moves.isEmpty {
            return await TransferCenter.shared.copy(moves.map { URL(fileURLWithPath: $0) }, into: directory, move: true)
        }
        let urls = await AttachmentStore.urls(from: providers)
        guard !urls.isEmpty else { return nil }
        return await TransferCenter.shared.copy(urls, into: directory, move: false)
    }

    static func send(_ providers: [NSItemProvider], into directory: String, channel: RemoteChannel) async -> String? {
        var moves: [String] = []
        for provider in providers {
            if let path = await movePath(from: provider) { moves.append(path) }
        }
        if !moves.isEmpty {
            for path in moves {
                if let failure = await Task.detached(operation: { channel.move(path, into: directory) }).value {
                    return failure
                }
            }
            return nil
        }
        let urls = await AttachmentStore.urls(from: providers)
        guard !urls.isEmpty else { return nil }
        return await TransferCenter.shared.upload(channel, urls, into: directory)
    }

    private static func movePath(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(FileDrop.moveType) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: FileDrop.moveType) { data, _ in
                continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }
}
