import AppKit
import Foundation
import TurmCore

final class CompanionBridge {
    private struct Entry {
        weak var session: TerminalSession?
        weak var workspace: Workspace?
        let pane: PaneID
    }

    private static let flushDelay: Duration = .milliseconds(16)
    private static let chunkLimit = 256 * 1024
    private static let maxInput = 64 * 1024

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var peers: [UUID: CompanionPeer] = [:]
    private var lastSummaries: [UUID: SessionSummary] = [:]
    private var pending: [UUID: [CompanionMessage]] = [:]
    private var dirty = false
    private var primed = false
    private var flushTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private let coordinator: CloseCoordinator
    private let shortcuts: ShortcutStore
    private let openFolder: (URL) -> Void

    init(
        coordinator: CloseCoordinator = .shared, shortcuts: ShortcutStore = .shared,
        openFolder: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.coordinator = coordinator
        self.shortcuts = shortcuts
        self.openFolder = openFolder
    }

    func peerAuthenticated(_ peer: CompanionPeer) {
        peers[peer.id] = peer
        scan()
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.scan()
            }
        }
    }

    func peerClosed(_ peer: CompanionPeer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        guard peers.isEmpty else { return }
        scanTask?.cancel()
        scanTask = nil
        flushTask?.cancel()
        flushTask = nil
        for entry in entries.values { entry.session?.companionTap = nil }
        entries = [:]
        order = []
        lastSummaries = [:]
        pending = [:]
        dirty = false
        primed = false
    }

    func handle(_ message: CompanionMessage, from peer: CompanionPeer) {
        switch message {
        case .listSessions:
            scan()
            peer.send(.sessions(order.compactMap { summary(for: $0) }))
        case .attach(let id):
            guard let session = entries[id]?.session else { return notFound(peer) }
            flush()
            peer.attached.insert(id)
            sendSnapshot(of: session, to: peer)
        case .detach(let id):
            peer.attached.remove(id)
        case .submit(let id, let text):
            guard let session = entries[id]?.session else { return notFound(peer) }
            if session.phase == .ready {
                session.submit(text)
            } else {
                peer.send(.error(code: CompanionErrorCode.notReady, text: "The shell is busy."))
            }
        case .input(let id, let bytes):
            guard let session = entries[id]?.session else { return notFound(peer) }
            guard bytes.count <= Self.maxInput else { return malformed(peer) }
            session.sendInput([UInt8](bytes))
        case .interrupt(let id):
            guard let session = entries[id]?.session else { return notFound(peer) }
            session.interrupt()
        case .resize(let id, let cols, let rows):
            guard let session = entries[id]?.session else { return notFound(peer) }
            guard (2...500).contains(cols), (2...300).contains(rows) else { return malformed(peer) }
            session.resize(cols: cols, rows: rows)
        case .create(let directory, let command):
            create(directory: directory, command: command, for: peer)
        case .close(let id, let force):
            close(id, force: force, for: peer)
        case .directoryShortcut(let path):
            guard Self.isAbsolute(path) else { return malformed(peer) }
            let existing = shortcuts.directory(at: path)
            let folder = (path as NSString).lastPathComponent
            let draft = existing ?? Shortcut(kind: .directory, key: Shortcuts.sanitize(folder).lowercased(), name: folder, value: path)
            peer.send(.directoryShortcutInfo(path: path, existing: existing, draft: draft))
        case .commandShortcut(let command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, command.utf8.count <= Self.maxText else { return malformed(peer) }
            let existing = shortcuts.items.first {
                $0.kind == .command && $0.value.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }
            let draft = existing ?? Shortcut(
                kind: .command, key: ShortcutSuggestions.commandKey(for: trimmed, in: shortcuts.items), name: "", value: command
            )
            peer.send(.commandShortcutInfo(command: command, existing: existing, draft: draft))
        case .listShortcuts:
            peer.send(.shortcuts(shortcuts.items))
        case .saveShortcut(let shortcut):
            save(shortcut, for: peer)
        case .removeShortcut(let id):
            guard shortcuts.items.contains(where: { $0.id == id }) else {
                return reply(peer, CompanionErrorCode.notFound, "That shortcut no longer exists.")
            }
            shortcuts.remove(id)
            peer.send(.ok(request: "removeShortcut"))
            peer.send(.shortcuts(shortcuts.items))
        case .listBranches(let id):
            guard let session = entries[id]?.session else { return notFound(peer) }
            listBranches(of: session, for: peer)
        case .switchBranch(let id, let name):
            guard let session = entries[id]?.session else { return notFound(peer) }
            switchBranch(of: session, to: name, for: peer)
        case .revealInFinder(let path):
            reveal(path, for: peer)
        case .listDirectory(let id, let path):
            listDirectory(id: id, path: path, for: peer)
        case .readFile(let id, let path):
            readFile(id: id, path: path, for: peer)
        case .writeFile(let id, let path, let data, let overwrite):
            writeFile(id: id, path: path, data: data, overwrite: overwrite, for: peer)
        case .diff(let id, let scope):
            diff(id: id, scope: scope, for: peer)
        case .cancelTransfer(_):
            peer.send(.ok(request: "cancelTransfer"))
        default:
            malformed(peer)
        }
    }

    private static let maxText = 4096

    private static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024 && !path.contains("\0")
    }

    private func reply(_ peer: CompanionPeer, _ code: String, _ text: String) {
        peer.send(.error(code: code, text: text))
    }

    private func fail(_ peer: CompanionPeer, _ text: String) {
        reply(peer, CompanionErrorCode.failed, text)
    }

    private func existsAsDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return Self.isAbsolute(path) && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func save(_ shortcut: Shortcut, for peer: CompanionPeer) {
        let key = Shortcuts.sanitize(shortcut.key)
        let value = shortcut.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count <= 64, shortcut.name.count <= 128, value.utf8.count <= Self.maxText, !value.contains("\0") else {
            return malformed(peer)
        }
        guard !key.isEmpty else { return fail(peer, "A shortcut needs a name.") }
        guard !value.isEmpty else { return fail(peer, "A shortcut needs a value.") }
        switch shortcut.kind {
        case .directory:
            guard existsAsDirectory(value) else { return fail(peer, "That folder does not exist on the Mac.") }
        case .file:
            guard Self.isAbsolute(value), FileManager.default.fileExists(atPath: value) else {
                return fail(peer, "That file does not exist on the Mac.")
            }
        case .command:
            break
        }
        if let conflict = Shortcuts.conflict(for: key, kind: shortcut.kind, excluding: shortcut.id, in: shortcuts.items) {
            let used = conflict.kind == .command ? conflict.value : Block.abbreviate(conflict.value)
            return fail(peer, "\(conflict.token) is already used by \(used).")
        }
        var entry = shortcut
        entry.projectRoot = nil
        guard shortcuts.save(entry) else { return fail(peer, "The shortcut could not be saved.") }
        peer.send(.ok(request: "saveShortcut"))
        peer.send(.shortcuts(shortcuts.items))
    }

    private func listBranches(of session: TerminalSession, for peer: CompanionPeer) {
        guard session.phase == .ready else { return reply(peer, CompanionErrorCode.notReady, "The shell is busy.") }
        Task { [weak session] in
            guard let session else { return }
            let names = await session.branches()
            peer.send(.branches(id: session.id, names: names, current: session.git?.branch))
        }
    }

    private func switchBranch(of session: TerminalSession, to name: String, for peer: CompanionPeer) {
        guard session.phase == .ready else { return reply(peer, CompanionErrorCode.notReady, "The shell is busy.") }
        guard !name.isEmpty, name.utf8.count <= 256 else { return malformed(peer) }
        Task { [weak session] in
            guard let session else { return }
            guard await session.branches().contains(name) else {
                peer.send(.error(code: CompanionErrorCode.notFound, text: "That branch does not exist."))
                return
            }
            guard session.phase == .ready else {
                peer.send(.error(code: CompanionErrorCode.notReady, text: "The shell is busy."))
                return
            }
            let failure = await session.switchBranch(to: name)
            peer.send(.branchSwitched(id: session.id, name: name, failure: failure))
        }
    }

    private func reveal(_ path: String, for peer: CompanionPeer) {
        guard Self.isAbsolute(path) else { return malformed(peer) }
        guard existsAsDirectory(path) else { return fail(peer, "That folder does not exist on the Mac.") }
        openFolder(URL(fileURLWithPath: path, isDirectory: true))
        peer.send(.ok(request: "revealInFinder"))
    }

    private func notFound(_ peer: CompanionPeer) {
        peer.send(.error(code: CompanionErrorCode.notFound, text: "That shell no longer exists."))
    }

    private func malformed(_ peer: CompanionPeer) {
        peer.send(.error(code: CompanionErrorCode.malformed, text: "That request was not understood."))
    }

    private func create(directory: String?, command: String?, for peer: CompanionPeer) {
        let workspaces = coordinator.registeredWorkspaces
        guard let workspace = workspaces.first(where: { $0.openShellCount > 0 }) ?? workspaces.first else {
            peer.send(.error(code: CompanionErrorCode.failed, text: "Turm has no open window on the Mac."))
            return
        }
        var path: String?
        if let directory, !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                peer.send(.error(code: CompanionErrorCode.failed, text: "That folder does not exist on the Mac."))
                return
            }
            path = expanded
        }
        workspace.newShell(directory: path, command: command)
        scan()
    }

    private func close(_ id: UUID, force: Bool, for peer: CompanionPeer) {
        guard let entry = entries[id], let workspace = entry.workspace else { return notFound(peer) }
        if workspace.closeRemotely(entry.pane, force: force) {
            scan()
        } else if force {
            peer.send(.error(code: CompanionErrorCode.failed, text: "The shell could not be closed."))
        } else {
            peer.send(.confirmClose(id: id, message: CloseRequest.shell.message))
        }
    }

    private func scan() {
        var seen: Set<UUID> = []
        var added: [UUID] = []
        for workspace in coordinator.registeredWorkspaces {
            for (pane, session) in workspace.sessionEntries where session.isOpen {
                seen.insert(session.id)
                if let existing = entries[session.id] {
                    // a shell dragged into another window keeps its id but changes workspace
                    if existing.workspace !== workspace { entries[session.id] = Entry(session: session, workspace: workspace, pane: pane) }
                    continue
                }
                entries[session.id] = Entry(session: session, workspace: workspace, pane: pane)
                order.append(session.id)
                added.append(session.id)
                session.companionTap = { [weak self, weak session] event in
                    guard let self, let session else { return }
                    self.receive(event, from: session)
                }
            }
        }
        for session in WindowTransfer.shared.pendingSessions { seen.insert(session.id) }
        for id in order where !seen.contains(id) { remove(id) }
        if primed {
            for id in added { announce(id) }
        }
        primed = true
        refreshSummaries()
    }

    private func remove(_ id: UUID) {
        entries[id]?.session?.companionTap = nil
        entries[id] = nil
        order.removeAll { $0 == id }
        lastSummaries[id] = nil
        pending[id] = nil
        for peer in peers.values { peer.attached.remove(id) }
        broadcast(.sessionClosed(id: id))
    }

    private func announce(_ id: UUID) {
        guard let summary = summary(for: id) else { return }
        lastSummaries[id] = summary
        broadcast(.sessionChanged(summary))
    }

    private func refreshSummaries() {
        for id in order {
            guard let summary = summary(for: id), lastSummaries[id] != summary else { continue }
            lastSummaries[id] = summary
            broadcast(.sessionChanged(summary))
        }
    }

    private func broadcast(_ message: CompanionMessage) {
        for peer in peers.values { peer.send(message) }
    }

    private func summary(for id: UUID) -> SessionSummary? {
        guard let entry = entries[id], let session = entry.session else { return nil }
        return SessionSummary(
            id: id, title: session.title, location: session.location, phase: Self.phase(of: session),
            activity: Self.activity(of: session), remoteLabel: session.remoteLabel, windowTitle: entry.workspace?.focusedTitle,
            branch: session.git?.branch, directory: session.directory, program: session.displayedProgram
        )
    }

    private static func git(_ status: GitStatus?) -> CompanionGit? {
        status.map { CompanionGit(branch: $0.branch, files: $0.files, added: $0.added, removed: $0.removed) }
    }

    private static func phase(of session: TerminalSession) -> CompanionPhase {
        session.phase == .ready ? .ready : .running
    }

    private static func activity(of session: TerminalSession) -> CompanionActivity {
        switch session.activity {
        case .inactive: .inactive
        case .working: .working
        case .progress(let percent): .progress(percent: percent)
        case .succeeded: .succeeded
        case .failed: .failed
        }
    }

    private func receive(_ event: CompanionSessionEvent, from session: TerminalSession) {
        let id = session.id
        switch event {
        case .blockStarted(let blockID, let command, let location):
            let block = session.blocks.first { $0.id == blockID }
            enqueue(
                .blockStarted(
                    id: id, blockID: blockID, command: command, location: location, directory: block?.directory ?? session.directory,
                    git: Self.git(block?.git), host: block?.host
                ),
                for: id
            )
        case .output(let blockID, let bytes):
            enqueueOutput(bytes, block: blockID, for: id)
        case .blockFinished(let blockID, let exitCode):
            enqueue(.blockFinished(id: id, blockID: blockID, exitCode: exitCode), for: id)
        case .phase(let phase, let directory):
            enqueue(.phase(id: id, phase: phase, directory: directory), for: id)
        case .notice(let text):
            let block = UUID()
            enqueue(
                .blockStarted(id: id, blockID: block, command: "", location: session.location, directory: session.directory, git: nil, host: nil),
                for: id
            )
            enqueueOutput(Data((text + "\r\n").utf8), block: block, for: id)
            enqueue(.blockFinished(id: id, blockID: block, exitCode: nil), for: id)
        case .title(let text):
            enqueue(.title(id: id, text: text), for: id)
        case .terminated:
            remove(id)
            return
        }
        dirty = true
        scheduleFlush()
    }

    private func hasListener(_ id: UUID) -> Bool {
        peers.values.contains { $0.attached.contains(id) }
    }

    private func enqueue(_ message: CompanionMessage, for id: UUID) {
        guard hasListener(id) else { return }
        pending[id, default: []].append(message)
    }

    private func enqueueOutput(_ bytes: Data, block: UUID, for id: UUID) {
        guard hasListener(id), !bytes.isEmpty else { return }
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + Self.chunkLimit, bytes.endIndex)
            let chunk = bytes[offset..<end]
            offset = end
            var queue = pending[id, default: []]
            if case .output(_, let last, let existing)? = queue.last, last == block, existing.count + chunk.count <= Self.chunkLimit {
                queue[queue.count - 1] = .output(id: id, blockID: block, bytes: existing + chunk)
            } else {
                queue.append(.output(id: id, blockID: block, bytes: Data(chunk)))
            }
            pending[id] = queue
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        let batches = pending
        pending = [:]
        for (id, messages) in batches {
            for peer in peers.values where peer.attached.contains(id) {
                for message in messages { peer.send(message) }
            }
        }
        if dirty {
            dirty = false
            refreshSummaries()
        }
    }

    private func listDirectory(id: UUID, path: String, for peer: CompanionPeer) {
        guard let session = entries[id]?.session else { return notFound(peer) }
        let sessionDir = session.directory
        guard !sessionDir.isEmpty else { return fail(peer, "Session has no directory.") }

        let listPath: String
        switch CompanionWrites.decide(uploadsEnabled: true, path: path, allowedRoot: sessionDir, overwrite: true, exists: false) {
        case .allow(let normalized):
            listPath = normalized
        case .refuse(_):
            let normPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let normRoot = URL(fileURLWithPath: sessionDir).standardized.path
            guard normPath == normRoot else { return fail(peer, "Path is outside the session directory.") }
            listPath = normRoot
        }

        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: listPath)
        } catch {
            return fail(peer, error.localizedDescription)
        }

        let dirEntries: [RemoteFileEntry] = names.prefix(CompanionFileLimits.maxListing).compactMap { name in
            let childPath = (listPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childPath, isDirectory: &isDir) else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: childPath)
            return RemoteFileEntry(
                name: name,
                isDirectory: isDir.boolValue,
                size: (attrs?[.size] as? NSNumber)?.int64Value,
                modified: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
            )
        }
        peer.send(.directoryListing(id: id, path: listPath, entries: dirEntries))
    }

    private func readFile(id: UUID, path: String, for peer: CompanionPeer) {
        guard let session = entries[id]?.session else { return notFound(peer) }
        let sessionDir = session.directory
        guard !sessionDir.isEmpty else { return fail(peer, "Session has no directory.") }

        let normalizedPath: String
        switch CompanionWrites.decide(uploadsEnabled: true, path: path, allowedRoot: sessionDir, overwrite: true, exists: false) {
        case .allow(let p):
            normalizedPath = p
        case .refuse:
            return fail(peer, "Path is outside the session directory.")
        }

        guard FileManager.default.fileExists(atPath: normalizedPath) else { return notFound(peer) }

        do {
            let raw = try Data(contentsOf: URL(fileURLWithPath: normalizedPath))
            let (data, truncated) = CompanionFileLimits.cappedData(raw, limit: CompanionFileLimits.maxRead)
            peer.send(.fileContents(id: id, path: normalizedPath, data: data, truncated: truncated))
        } catch {
            fail(peer, error.localizedDescription)
        }
    }

    private func writeFile(id: UUID, path: String, data: Data, overwrite: Bool, for peer: CompanionPeer) {
        guard entries[id]?.session != nil else { return notFound(peer) }

        let exists = FileManager.default.fileExists(atPath: path)
        if let sessionDir = entries[id]?.session?.directory,
           let allowed = Self.allowed(path, root: sessionDir, overwrite: overwrite, exists: exists) {
            return write(allowed, data: data, peer: peer, request: "writeFile")
        }

        let uploadsOn = UserDefaults.standard.bool(forKey: "turm.companion.uploads")
        let uploadRoot = UserDefaults.standard.string(forKey: "turm.companion.uploadRoot") ?? ""
        guard uploadsOn, !uploadRoot.isEmpty else {
            return fail(peer, "File uploads are not enabled.")
        }
        guard data.count <= CompanionFileLimits.maxWrite else {
            return fail(peer, "File exceeds the maximum upload size.")
        }
        switch CompanionWrites.decide(uploadsEnabled: true, path: path, allowedRoot: uploadRoot, overwrite: overwrite, exists: exists) {
        case .refuse(let reason):
            return fail(peer, reason)
        case .allow(let normalizedPath):
            let resolvedPath = URL(fileURLWithPath: normalizedPath).resolvingSymlinksInPath().path
            let resolvedRoot = URL(fileURLWithPath: uploadRoot).resolvingSymlinksInPath().path
            guard Self.isDescendant(resolvedPath, of: resolvedRoot) else {
                return fail(peer, "Path is outside the allowed root after symlink resolution.")
            }
            write(resolvedPath, data: data, peer: peer, request: "writeFile")
        }
    }

    private static func allowed(_ path: String, root: String, overwrite: Bool, exists: Bool) -> String? {
        guard !root.isEmpty else { return nil }
        switch CompanionWrites.decide(uploadsEnabled: true, path: path, allowedRoot: root, overwrite: overwrite, exists: exists) {
        case .allow(let normalized):
            let resolvedPath = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            guard isDescendant(resolvedPath, of: resolvedRoot) else { return nil }
            return resolvedPath
        case .refuse:
            return nil
        }
    }

    private func write(_ path: String, data: Data, peer: CompanionPeer, request: String) {
        guard data.count <= CompanionFileLimits.maxWrite else {
            return fail(peer, "File exceeds the maximum upload size.")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            peer.send(.ok(request: request))
        } catch {
            fail(peer, error.localizedDescription)
        }
    }

    private func diff(id: UUID, scope: CompanionDiffScope, for peer: CompanionPeer) {
        guard let session = entries[id]?.session else { return notFound(peer) }
        let sessionDir = session.directory
        guard !sessionDir.isEmpty else { return fail(peer, "Session has no directory.") }

        let args: [String]
        switch scope {
        case .unstaged:
            args = ["diff"]
        case .staged:
            args = ["diff", "--cached"]
        case .commit(let sha):
            guard (4...64).contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else {
                return malformed(peer)
            }
            args = ["show", sha]
        }

        let capturedID = id
        let dir = sessionDir
        Task {
            do {
                let outputData = try await Self.gitOutput(args, in: dir)
                let rawText = String(decoding: outputData, as: UTF8.self)
                let (text, truncated) = CompanionFileLimits.cappedText(rawText, limit: CompanionFileLimits.maxDiff)
                peer.send(.diffResult(id: capturedID, text: text, truncated: truncated))
            } catch {
                peer.send(.error(code: CompanionErrorCode.failed, text: "git: \(error.localizedDescription)"))
            }
        }
    }

    private static func gitOutput(_ args: [String], in directory: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { p in
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let err = NSError(
                        domain: "git", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "git exited with status \(p.terminationStatus)"]
                    )
                    continuation.resume(throwing: err)
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        if root == "/" { return path != "/" }
        return path.hasPrefix(root + "/")
    }

    private func sendSnapshot(of session: TerminalSession, to peer: CompanionPeer) {
        for divisor in [1, 4, 16] {
            if peer.send(snapshot(of: session, divisor: divisor)) { return }
        }
        peer.send(.error(code: CompanionErrorCode.failed, text: "The shell history is too large to send."))
    }

    private static func styledOutput(of block: Block, limit: Int) -> Data {
        var lines = block.emulator.styledLines(maxBytes: limit)
        var data = StyledOutput.encode(lines)
        let cap = limit * 2
        while data.count > cap, lines.count > 1 {
            lines.removeFirst(max(1, lines.count / 4))
            data = StyledOutput.encode(lines)
        }
        return data.count > cap ? Data() : data
    }

    func snapshot(of session: TerminalSession, divisor: Int) -> CompanionMessage {
        let size = session.getWindowSize()
        var budget = 1_000_000 / divisor
        var history: [BlockSummary] = []
        for block in session.blocks.reversed() where !block.isRunning {
            let textLimit = 200_000 / divisor
            let text = String((block.notice ?? block.plainOutput).suffix(textLimit))
            let base = text.utf8.count + block.command.utf8.count + 256
            var styled: Data?
            if block.notice == nil, !text.isEmpty {
                let candidate = Self.styledOutput(of: block, limit: textLimit)
                if !candidate.isEmpty, budget - base - candidate.count >= 0 { styled = candidate }
            }
            budget -= base + (styled?.count ?? 0)
            if budget < 0 { break }
            history.append(BlockSummary(
                id: block.id, command: block.command, location: block.location, exitCode: block.exitCode, text: text,
                directory: block.directory, git: Self.git(block.git), host: block.host, connectedTo: block.connectedTo,
                duration: block.duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 },
                styled: styled
            ))
        }
        history.reverse()
        let running = session.current.map {
            RunningBlock(
                id: $0.id, command: $0.command, location: $0.location, bytes: Data($0.rawBytes.suffix(700_000 / divisor)),
                directory: $0.directory, git: Self.git($0.git), host: $0.host
            )
        }
        return .snapshot(id: session.id, cols: Int(size.ws_col), rows: Int(size.ws_row), history: history, running: running)
    }
}
