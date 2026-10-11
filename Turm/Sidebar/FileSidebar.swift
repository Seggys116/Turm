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
    @State private var expandable: Set<String> = []
    @State private var expandableToken = 0
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
        .frame(width: 220)
        .background(Theme.sidebar.color)
        .onChange(of: session.directory, initial: true) { _, path in
            root = path
            expanded = []
            children = [:]
            expandable = []
            reloadRoot()
        }
        .onChange(of: session.connection?.integrated) { _, _ in
            reloadRoot()
        }
        .onChange(of: includeHidden) { _, _ in
            refreshExpandable()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(PathDisplay.abbreviate(root))
                .font(.system(size: 11, weight: .medium))
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
            Button {
                session.showsFiles = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText.color)
            .help("Hide Files")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .modifier(DirectoryDrop(directory: root, receive: { providers, folder in
            receive(providers, into: folder)
        }))
    }

    private var filterField: some View {
        TextField("Filter", text: $filter)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.chipFill.color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
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
            .squareScrollbar()
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
            if entry.isDirectory, expandable.contains(entry.path) {
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
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(targeted == entry.path ? Theme.dropFill.color : Color.clear)
        .contentShape(Rectangle())
        .onDrag { provider(for: entry) }
        .onDrop(of: dropTypes, isTargeted: binding(for: entry.path)) { providers in
            guard entry.isDirectory else { return false }
            receive(providers, into: entry.path, fromRow: true)
            return true
        }
        .onTapGesture {
            guard entry.isDirectory, expandable.contains(entry.path) else { return }
            toggle(entry.path)
        }
        .onTapGesture(count: 2) {
            guard !entry.isDirectory else { return }
            openFile(entry)
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

    private var dropTypes: [UTType] {
        [.fileURL, UTType(importedAs: FileDrop.moveType)]
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { targeted == path },
            set: { isTargeted in
                if isTargeted { targeted = path } else if targeted == path { targeted = nil }
            }
        )
    }

    private func provider(for entry: FileEntry) -> NSItemProvider {
        let provider = NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL)
        let path = entry.path
        provider.registerDataRepresentation(forTypeIdentifier: FileDrop.moveType, visibility: .ownProcess) { completion in
            completion(Data(path.utf8), nil)
            return nil
        }
        provider.suggestedName = entry.name
        return provider
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
            refreshExpandable()
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
            refreshExpandable()
        }
    }

    private func refreshExpandable() {
        expandableToken += 1
        let token = expandableToken
        let hidden = includeHidden
        let currentRoot = root
        let paths = directoryPaths()
        let channel = session.remoteChannel
        let remote = session.isRemote
        Task {
            let found: Set<String>
            if let channel {
                found = await Task.detached { channel.directoriesWithVisibleEntries(paths, includeHidden: hidden) }.value
            } else if remote {
                found = []
            } else {
                found = await Task.detached {
                    LocalDirectory.directoriesWithVisibleEntries(paths, includeHidden: hidden)
                }.value
            }
            guard token == expandableToken, root == currentRoot else { return }
            expandable = found
            expanded.formIntersection(found)
        }
    }

    private func directoryPaths() -> [String] {
        var paths: [String] = []
        func collect(_ entries: [FileEntry]) {
            for entry in entries where entry.isDirectory {
                paths.append(entry.path)
                if let listed = children[entry.path] {
                    collect(listed.entries)
                }
            }
        }
        collect(listing.entries)
        return paths
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
