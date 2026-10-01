import Foundation
import Network
import Testing
import TurmCore
@testable import Turm

@MainActor
private final class Outbox {
    var messages: [CompanionMessage] = []
    var presented: [CloseRequest] = []
    var opened: [URL] = []

    var errorCodes: [String] {
        messages.compactMap { if case .error(let code, _) = $0 { code } else { nil } }
    }

    var snapshots: [(id: UUID, cols: Int, rows: Int, history: [BlockSummary], running: RunningBlock?)] {
        messages.compactMap {
            if case .snapshot(let id, let cols, let rows, let history, let running) = $0 { (id, cols, rows, history, running) } else { nil }
        }
    }

    var changed: [SessionSummary] {
        messages.compactMap { if case .sessionChanged(let summary) = $0 { summary } else { nil } }
    }

    func output(for id: UUID) -> String {
        var data = Data()
        for case .output(let session, _, let bytes) in messages where session == id { data.append(bytes) }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private struct Rig {
    let outbox = Outbox()
    let coordinator: CloseCoordinator
    let workspace: Workspace
    let bridge: CompanionBridge
    let peer: CompanionPeer
    let session: TerminalSession
    let store: ShortcutStore
    private let suite = "turm.companion.tests." + UUID().uuidString

    init() throws {
        let outbox = outbox
        coordinator = CloseCoordinator {
            outbox.presented.append($0)
            return false
        }
        workspace = Workspace(closeCoordinator: coordinator)
        store = ShortcutStore(defaults: try #require(UserDefaults(suiteName: suite)))
        bridge = CompanionBridge(coordinator: coordinator, shortcuts: store, openFolder: { outbox.opened.append($0) })
        let connection = try #require(CompanionConnection(host: "127.0.0.1", port: 1, parameters: .tcp))
        peer = CompanionPeer(connection: connection, sink: {
            outbox.messages.append($0)
            return true
        })
        session = try #require(workspace.focusedSession)
        bridge.peerAuthenticated(peer)
    }

    func finish() {
        bridge.peerClosed(peer)
        coordinator.terminateAll()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turm-companion-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// waiting for git on the main actor stalls every shell test that needs it to reach the prompt
@concurrent
private nonisolated func runGit(_ arguments: [String], in repo: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
@Suite(.serialized)
struct CompanionBridgeTests {
    private func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func tapReportsABlockLifecycleInOrder() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        try #require(await wait { session.phase == .ready })
        var events: [CompanionSessionEvent] = []
        session.companionTap = { events.append($0) }

        session.submit("echo hi")
        try #require(await wait {
            guard let finished = events.firstIndex(where: { if case .blockFinished = $0 { true } else { false } }) else { return false }
            return events[finished...].contains { if case .phase(.ready, _) = $0 { true } else { false } }
        })

        let started = try #require(events.firstIndex { if case .blockStarted = $0 { true } else { false } })
        let finished = try #require(events.firstIndex { if case .blockFinished = $0 { true } else { false } })
        let ready = try #require(events.lastIndex { if case .phase(.ready, _) = $0 { true } else { false } })
        guard case .blockStarted(let blockID, let command, _) = events[started] else { return }
        #expect(command == "echo hi")
        #expect(started < finished && finished < ready)

        var output = Data()
        for (index, event) in events.enumerated() {
            if case .output(let id, let bytes) = event {
                #expect(id == blockID)
                #expect(index > started && index < finished)
                output.append(bytes)
            }
        }
        #expect(String(decoding: output, as: UTF8.self).contains("hi"))
        guard case .blockFinished(let finishedID, let exitCode) = events[finished] else { return }
        #expect(finishedID == blockID)
        #expect(exitCode == nil || exitCode == 0)
        #expect(events.contains { if case .phase(.running, _) = $0 { true } else { false } })
    }

    @Test func remoteCloseNeedsForceForABusyShellAndNeverAsksOnTheMac() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let pane = rig.workspace.focusedPane
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("sleep 30")
        try #require(await wait { rig.session.phase == .running })

        #expect(!rig.workspace.closeRemotely(pane, force: false))
        #expect(rig.session.isOpen)
        #expect(rig.workspace.session(for: pane) === rig.session)

        #expect(rig.workspace.closeRemotely(pane, force: true))
        #expect(!rig.session.isOpen)
        #expect(rig.workspace.session(for: pane) == nil)
        #expect(rig.outbox.presented.isEmpty)
    }

    @Test func remoteCloseOfAnIdleShellNeedsNoForce() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready && !rig.session.hasRunningJobs })

        #expect(rig.workspace.closeRemotely(rig.workspace.focusedPane, force: false))
        #expect(!rig.session.isOpen)
        #expect(rig.outbox.presented.isEmpty)
    }

    @Test func sessionsListDescribesTheOpenShell() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.listSessions, from: rig.peer)

        let lists = rig.outbox.messages.compactMap { if case .sessions(let list) = $0 { list } else { nil } }
        let list = try #require(lists.last)
        #expect(list.map(\.id) == [rig.session.id])
        #expect(list[0].phase == .ready)
        #expect(list[0].title == rig.session.title)
    }

    @Test func submitOnAReadySessionRunsTheCommand() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.submit(id: rig.session.id, text: "echo $((30+12))"), from: rig.peer)

        try #require(await wait { rig.session.blocks.contains { $0.command == "echo $((30+12))" && !$0.isRunning } })
        let block = try #require(rig.session.blocks.first { $0.command == "echo $((30+12))" })
        #expect(block.plainOutput.contains("42"))
        #expect(rig.outbox.errorCodes.isEmpty)
    }

    @Test func submitWhileRunningRepliesNotReadyAndDoesNotType() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("sleep 30")
        try #require(await wait { rig.session.phase == .running })
        let count = rig.session.blocks.count

        rig.bridge.handle(.submit(id: rig.session.id, text: "echo rejected"), from: rig.peer)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(rig.outbox.errorCodes == [CompanionErrorCode.notReady])
        #expect(rig.session.blocks.count == count)
        #expect(!rig.session.blocks.contains { $0.command == "echo rejected" })
        #expect(rig.session.phase == .running)
    }

    @Test func unknownSessionIdRepliesNotFoundForEveryTargetedRequest() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        let count = rig.session.blocks.count
        let ghost = UUID()

        rig.bridge.handle(.submit(id: ghost, text: "echo stray"), from: rig.peer)
        rig.bridge.handle(.attach(id: ghost), from: rig.peer)
        rig.bridge.handle(.input(id: ghost, bytes: Data("x".utf8)), from: rig.peer)
        rig.bridge.handle(.interrupt(id: ghost), from: rig.peer)
        rig.bridge.handle(.resize(id: ghost, cols: 80, rows: 24), from: rig.peer)
        rig.bridge.handle(.close(id: ghost, force: true), from: rig.peer)

        #expect(rig.outbox.errorCodes == Array(repeating: CompanionErrorCode.notFound, count: 6))
        #expect(rig.session.blocks.count == count)
        #expect(rig.session.isOpen)
        #expect(rig.peer.attached.isEmpty)
    }

    @Test func closeWithoutForceOnABusyShellAsksThePhoneNotTheMac() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("sleep 30")
        try #require(await wait { rig.session.phase == .running })

        rig.bridge.handle(.close(id: rig.session.id, force: false), from: rig.peer)

        #expect(rig.session.isOpen)
        #expect(rig.outbox.messages.contains(.confirmClose(id: rig.session.id, message: CloseRequest.shell.message)))
        #expect(rig.outbox.presented.isEmpty)
    }

    @Test func closeWithForceEndsTheShellAndAnnouncesIt() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("sleep 30")
        try #require(await wait { rig.session.phase == .running })
        let id = rig.session.id

        rig.bridge.handle(.close(id: id, force: true), from: rig.peer)

        #expect(!rig.session.isOpen)
        #expect(rig.outbox.messages.contains(.sessionClosed(id: id)))
        #expect(rig.outbox.presented.isEmpty)
        #expect(rig.outbox.errorCodes.isEmpty)
    }

    @Test func attachSendsAnIdleSnapshotWithFinishedBlocksOnly() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("echo $((20+22))")
        try #require(await wait { rig.session.phase == .ready && rig.session.blocks.contains { $0.command == "echo $((20+22))" && !$0.isRunning } })

        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)

        let snapshot = try #require(rig.outbox.snapshots.last)
        #expect(snapshot.id == rig.session.id)
        #expect(snapshot.cols > 0 && snapshot.rows > 0)
        #expect(snapshot.running == nil)
        let entry = try #require(snapshot.history.first { $0.command == "echo $((20+22))" })
        #expect(entry.text.contains("42"))
        #expect(entry.exitCode == nil || entry.exitCode == 0)
        #expect(rig.peer.attached.contains(rig.session.id))
    }

    @Test func snapshotHistoryKeepsTheColoursOfFinishedOutput() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        let command = #"printf '\033[31mred\033[0m plain\n'"#
        rig.session.submit(command)
        try #require(await wait { rig.session.phase == .ready && rig.session.blocks.contains { $0.command == command && !$0.isRunning } })

        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)

        let snapshot = try #require(rig.outbox.snapshots.last)
        let entry = try #require(snapshot.history.first { $0.command == command })
        let styled = String(decoding: try #require(entry.styled), as: UTF8.self)
        #expect(entry.text.contains("red plain"))
        #expect(styled.contains("\u{1B}[31mred\u{1B}[0m"))
        #expect(styled.contains("plain"))
    }

    @Test func snapshotOfARunningCommandCarriesItsOutputSoFar() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("echo before; sleep 30")
        try #require(await wait { rig.session.current.map { String(decoding: $0.rawBytes, as: UTF8.self).contains("before") } ?? false })

        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)

        let snapshot = try #require(rig.outbox.snapshots.last)
        let running = try #require(snapshot.running)
        #expect(running.command == "echo before; sleep 30")
        #expect(String(decoding: running.bytes, as: UTF8.self).contains("before"))
        #expect(running.id == rig.session.current?.id)
        #expect(!snapshot.history.contains { $0.id == running.id })
    }

    @Test func inputBytesReachARunningProgramAndComeBackAsOutput() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)
        rig.session.submit("cat")
        try #require(await wait { rig.session.phase == .running })

        rig.bridge.handle(.input(id: rig.session.id, bytes: Data("turmping\n".utf8)), from: rig.peer)

        #expect(await wait { rig.outbox.output(for: rig.session.id).contains("turmping") })
        rig.bridge.handle(.interrupt(id: rig.session.id), from: rig.peer)
        #expect(await wait { rig.session.phase == .ready })
    }

    @Test func oversizedInputIsRejectedAsMalformed() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.input(id: rig.session.id, bytes: Data(count: 64 * 1024 + 1)), from: rig.peer)

        #expect(rig.outbox.errorCodes == [CompanionErrorCode.malformed])
    }

    @Test func createOpensANewShellAndAnnouncesIt() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.create(directory: nil, command: nil), from: rig.peer)

        let entries = rig.workspace.sessionEntries
        #expect(entries.count == 2)
        let created = try #require(entries.map(\.session).first { $0 !== rig.session })
        #expect(rig.outbox.changed.contains { $0.id == created.id })
        #expect(rig.outbox.errorCodes.isEmpty)
    }

    @Test func createInAMissingFolderIsRefused() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.create(directory: "/definitely/not/a/folder-\(UUID().uuidString)", command: nil), from: rig.peer)

        #expect(rig.outbox.errorCodes == [CompanionErrorCode.failed])
        #expect(rig.workspace.sessionEntries.count == 1)
    }

    @Test func directoryShortcutQueryOffersADraftThenTheSavedShortcut() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let folder = try rig.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        rig.bridge.handle(.directoryShortcut(path: folder.path), from: rig.peer)
        guard case .directoryShortcutInfo(let path, let existing, let draft)? = rig.outbox.messages.last else {
            Issue.record("no directory shortcut reply")
            return
        }
        #expect(path == folder.path)
        #expect(existing == nil)
        #expect(draft.kind == .directory && draft.value == folder.path)
        #expect(draft.key == Shortcuts.sanitize(folder.lastPathComponent).lowercased())

        rig.bridge.handle(.saveShortcut(draft), from: rig.peer)
        #expect(rig.outbox.messages.contains(.ok(request: "saveShortcut")))
        rig.bridge.handle(.directoryShortcut(path: folder.path), from: rig.peer)
        guard case .directoryShortcutInfo(_, let saved, _)? = rig.outbox.messages.last else {
            Issue.record("no second reply")
            return
        }
        #expect(saved?.id == draft.id)
        #expect(rig.store.directory(at: folder.path)?.id == draft.id)
    }

    @Test func commandShortcutQueryFindsTheExistingOneByItsTrimmedCommand() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let command = Shortcut(kind: .command, key: "tests", name: "", value: "make test")
        rig.bridge.handle(.saveShortcut(command), from: rig.peer)

        rig.bridge.handle(.commandShortcut(command: "  make test \n"), from: rig.peer)
        guard case .commandShortcutInfo(_, let existing, _)? = rig.outbox.messages.last else {
            Issue.record("no command shortcut reply")
            return
        }
        #expect(existing?.id == command.id)

        rig.bridge.handle(.commandShortcut(command: "swift build"), from: rig.peer)
        guard case .commandShortcutInfo(_, let none, let draft)? = rig.outbox.messages.last else {
            Issue.record("no draft reply")
            return
        }
        #expect(none == nil)
        #expect(draft.kind == .command && !draft.key.isEmpty && draft.value == "swift build")
    }

    @Test func savingAShortcutAppliesTheEditorRules() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let folder = try rig.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        rig.bridge.handle(.saveShortcut(Shortcut(kind: .command, key: "  ", name: "", value: "ls")), from: rig.peer)
        rig.bridge.handle(.saveShortcut(Shortcut(kind: .command, key: "ls", name: "", value: "   ")), from: rig.peer)
        rig.bridge.handle(.saveShortcut(Shortcut(kind: .directory, key: "gone", name: "", value: "/definitely/not/here-\(UUID().uuidString)")), from: rig.peer)
        rig.bridge.handle(.saveShortcut(Shortcut(kind: .directory, key: "rel", name: "", value: "relative/path")), from: rig.peer)
        #expect(rig.outbox.errorCodes == Array(repeating: CompanionErrorCode.failed, count: 4))
        #expect(rig.store.items.isEmpty)

        rig.bridge.handle(.saveShortcut(Shortcut(kind: .directory, key: "work", name: " Work ", value: folder.path)), from: rig.peer)
        #expect(rig.store.items.map(\.key) == ["work"])
        #expect(rig.store.items.first?.name == "Work")

        rig.bridge.handle(.saveShortcut(Shortcut(kind: .directory, key: "work", name: "", value: folder.path)), from: rig.peer)
        #expect(rig.store.items.count == 1)
        let last = rig.outbox.messages.compactMap { if case .error(_, let text) = $0 { text } else { nil } }.last
        #expect(last?.contains("work") == true)

        let long = String(repeating: "a", count: 5000)
        rig.bridge.handle(.saveShortcut(Shortcut(kind: .command, key: "big", name: "", value: long)), from: rig.peer)
        #expect(rig.outbox.errorCodes.last == CompanionErrorCode.malformed)
        #expect(rig.store.items.count == 1)
    }

    @Test func projectRootIsNeverAcceptedFromThePhone() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let shortcut = Shortcut(kind: .command, key: "proj", name: "", value: "ls", projectRoot: "/tmp")

        rig.bridge.handle(.saveShortcut(shortcut), from: rig.peer)

        #expect(rig.store.items.first?.projectRoot == nil)
    }

    @Test func removingShortcutsAndListingThem() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let shortcut = Shortcut(kind: .command, key: "tests", name: "", value: "make test")
        rig.bridge.handle(.saveShortcut(shortcut), from: rig.peer)

        rig.bridge.handle(.listShortcuts, from: rig.peer)
        #expect(rig.outbox.messages.last == .shortcuts(rig.store.items))
        #expect(rig.store.items.map(\.id) == [shortcut.id])

        rig.bridge.handle(.removeShortcut(id: UUID()), from: rig.peer)
        #expect(rig.outbox.errorCodes == [CompanionErrorCode.notFound])
        #expect(rig.store.items.count == 1)

        rig.bridge.handle(.removeShortcut(id: shortcut.id), from: rig.peer)
        #expect(rig.store.items.isEmpty)
        #expect(rig.outbox.messages.contains(.ok(request: "removeShortcut")))
    }

    @Test func revealInFinderOpensExistingFoldersOnly() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let folder = try rig.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)

        rig.bridge.handle(.revealInFinder(path: file.path), from: rig.peer)
        rig.bridge.handle(.revealInFinder(path: folder.path + "/missing"), from: rig.peer)
        rig.bridge.handle(.revealInFinder(path: "relative"), from: rig.peer)
        rig.bridge.handle(.revealInFinder(path: "/" + String(repeating: "a", count: 2000)), from: rig.peer)
        #expect(rig.outbox.opened.isEmpty)
        #expect(rig.outbox.errorCodes == [
            CompanionErrorCode.failed, CompanionErrorCode.failed, CompanionErrorCode.malformed, CompanionErrorCode.malformed,
        ])

        rig.bridge.handle(.revealInFinder(path: folder.path), from: rig.peer)
        #expect(rig.outbox.opened.map(\.path) == [folder.path])
        #expect(rig.outbox.messages.last == .ok(request: "revealInFinder"))
    }

    @Test func branchRequestsForUnknownShellsAreNotFound() async throws {
        let rig = try Rig()
        defer { rig.finish() }

        rig.bridge.handle(.listBranches(id: UUID()), from: rig.peer)
        rig.bridge.handle(.switchBranch(id: UUID(), name: "main"), from: rig.peer)

        #expect(rig.outbox.errorCodes == [CompanionErrorCode.notFound, CompanionErrorCode.notFound])
    }

    @Test func branchRequestsWaitForAReadyShell() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.session.submit("sleep 30")
        try #require(await wait { rig.session.phase == .running })

        rig.bridge.handle(.listBranches(id: rig.session.id), from: rig.peer)
        rig.bridge.handle(.switchBranch(id: rig.session.id, name: "main"), from: rig.peer)

        #expect(rig.outbox.errorCodes == [CompanionErrorCode.notReady, CompanionErrorCode.notReady])
    }

    @Test func listingBranchesReportsTheNamesAndTheCurrentOne() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.listBranches(id: rig.session.id), from: rig.peer)

        try #require(await wait { rig.outbox.messages.contains { if case .branches = $0 { true } else { false } } })
        guard case .branches(let id, let names, let current)? = rig.outbox.messages.last(where: { if case .branches = $0 { true } else { false } }) else { return }
        #expect(id == rig.session.id)
        #expect(current == rig.session.git?.branch)
        #expect(Set(names).count == names.count)
    }

    @Test func switchingToAnUnlistedBranchIsRefusedBeforeGitRuns() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.switchBranch(id: rig.session.id, name: "--orphan=evil; rm -rf ~"), from: rig.peer)

        try #require(await wait { !rig.outbox.errorCodes.isEmpty })
        #expect(rig.outbox.errorCodes == [CompanionErrorCode.notFound])
        #expect(!rig.outbox.messages.contains { if case .branchSwitched = $0 { true } else { false } })
    }

    @Test func switchingBranchesReportsGitsFailureText() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let repo = try rig.folder()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await runGit(["init", "-b", "main"], in: repo)
        try Data("a".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try await runGit(["add", "."], in: repo)
        try await runGit(["commit", "-m", "one"], in: repo)
        try await runGit(["branch", "other"], in: repo)
        rig.workspace.newShell(directory: repo.path)
        let session = try #require(rig.workspace.sessionEntries.map(\.session).first { $0 !== rig.session })
        try #require(await wait { session.phase == .ready })
        rig.bridge.handle(.listSessions, from: rig.peer)

        rig.bridge.handle(.listBranches(id: session.id), from: rig.peer)
        try #require(await wait { rig.outbox.messages.contains { if case .branches = $0 { true } else { false } } })
        guard case .branches(_, let names, _)? = rig.outbox.messages.last(where: { if case .branches = $0 { true } else { false } }) else { return }
        #expect(Set(names) == ["main", "other"])

        rig.bridge.handle(.switchBranch(id: session.id, name: "other"), from: rig.peer)
        try #require(await wait { rig.outbox.messages.contains { if case .branchSwitched = $0 { true } else { false } } })
        #expect(rig.outbox.messages.contains(.branchSwitched(id: session.id, name: "other", failure: nil)))
    }

    @Test func blockStartAndSnapshotCarryDirectoryGitAndHost() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })
        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)
        let directory = rig.session.directory

        rig.session.submit("echo carried")
        try #require(await wait { rig.session.phase == .ready && rig.session.blocks.contains { $0.command == "echo carried" && !$0.isRunning } })
        try #require(await wait {
            rig.outbox.messages.contains { if case .blockStarted(_, _, "echo carried", _, _, _, _) = $0 { true } else { false } }
        })

        guard case .blockStarted(_, let blockID, _, _, let sent, _, let host)? = rig.outbox.messages.first(where: {
            if case .blockStarted(_, _, "echo carried", _, _, _, _) = $0 { true } else { false }
        }) else { return }
        #expect(sent == directory)
        #expect(host == nil)
        let block = try #require(rig.session.blocks.first { $0.id == blockID })
        #expect(block.git?.branch == rig.session.git?.branch || block.git == nil)

        rig.bridge.handle(.detach(id: rig.session.id), from: rig.peer)
        rig.bridge.handle(.attach(id: rig.session.id), from: rig.peer)
        let entry = try #require(rig.outbox.snapshots.last?.history.first { $0.command == "echo carried" })
        #expect(entry.directory == directory)
        #expect(entry.host == nil)
        #expect(entry.duration != nil)
    }

    @Test func sessionSummaryCarriesDirectoryAndBranch() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try #require(await wait { rig.session.phase == .ready })

        rig.bridge.handle(.listSessions, from: rig.peer)

        let list = try #require(rig.outbox.messages.compactMap { if case .sessions(let list) = $0 { list } else { nil } }.last)
        #expect(list[0].directory == rig.session.directory)
        #expect(list[0].branch == rig.session.git?.branch)
    }

    @Test func lastPeerLeavingDetachesEverySession() async throws {
        let rig = try Rig()
        defer { rig.coordinator.terminateAll() }
        try #require(await wait { rig.session.phase == .ready })
        #expect(rig.session.companionTap != nil)

        rig.bridge.peerClosed(rig.peer)

        #expect(rig.session.companionTap == nil)
    }
}
