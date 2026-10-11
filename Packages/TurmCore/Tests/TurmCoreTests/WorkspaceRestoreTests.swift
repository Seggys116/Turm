import Foundation
import Testing
@testable import TurmCore

struct WorkspaceRestoreTests {

    private func makeTwoWindowDocument() -> WorkspaceDocument {
        let pane1ID = UUID()
        let pane2ID = UUID()
        let pane3ID = UUID()
        let splitHID = UUID()
        let splitVID = UUID()

        let horizontalSplit = SavedPaneNode.split(
            id: splitHID,
            axis: .horizontal,
            ratio: 0.4,
            first: .leaf(pane1ID),
            second: .leaf(pane2ID)
        )
        let layout1 = SavedPaneNode.split(
            id: splitVID,
            axis: .vertical,
            ratio: 0.6,
            first: horizontalSplit,
            second: .leaf(pane3ID)
        )

        let sshHostID = UUID()
        let pane1 = SavedPane(
            id: pane1ID,
            content: .shell(SavedShell(directory: "/home/user", shell: .zsh, history: ["ls", "cd ~"], sshHostID: sshHostID)),
            showsFiles: true
        )
        let pane2 = SavedPane(
            id: pane2ID,
            content: .shell(SavedShell(directory: "/tmp", shell: .bash, history: [])),
            showsFiles: false
        )
        let pane3 = SavedPane(
            id: pane3ID,
            content: .diff(SavedDiff(directory: "/repo", scope: .commit("abc123"), layout: .sideBySide)),
            showsFiles: false
        )

        let tab1ID = UUID()
        let tab1 = SavedTab(id: tab1ID, title: "Dev", layout: layout1, focusedPane: pane2ID)

        let window1ID = UUID()
        let window1 = SavedWindow(
            id: window1ID,
            frame: SavedFrame(x: 100, y: 50, width: 1200, height: 800),
            tabs: [tab1],
            activeTabID: tab1ID,
            panes: [pane1, pane2, pane3]
        )

        let pane4ID = UUID()
        let pane4 = SavedPane(
            id: pane4ID,
            content: .shell(SavedShell(directory: "/", shell: .fish, history: []))
        )
        let tab2ID = UUID()
        let tab2 = SavedTab(id: tab2ID, title: nil, layout: .leaf(pane4ID), focusedPane: pane4ID)
        let window2ID = UUID()
        let window2 = SavedWindow(
            id: window2ID,
            frame: nil,
            tabs: [tab2],
            activeTabID: tab2ID,
            panes: [pane4]
        )

        return WorkspaceDocument(windows: [window1, window2], keyWindowID: window2ID)
    }

    @Test func jsonRoundTripOfComplexDocument() throws {
        let doc = makeTwoWindowDocument()
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        #expect(decoded == doc)
    }

    @Test func normalizedClampsRatioBelowMinimum() {
        let leafA = UUID()
        let leafB = UUID()
        let splitID = UUID()
        let node = SavedPaneNode.split(id: splitID, axis: .horizontal, ratio: 0, first: .leaf(leafA), second: .leaf(leafB))
        let expected = SavedPaneNode.split(id: splitID, axis: .horizontal, ratio: SavedPaneNode.minimumRatio, first: .leaf(leafA), second: .leaf(leafB))
        #expect(node.normalized() == expected)
    }

    @Test func normalizedClampsRatioAboveMaximum() {
        let leafA = UUID()
        let leafB = UUID()
        let splitID = UUID()
        let node = SavedPaneNode.split(id: splitID, axis: .vertical, ratio: 2, first: .leaf(leafA), second: .leaf(leafB))
        let expected = SavedPaneNode.split(id: splitID, axis: .vertical, ratio: SavedPaneNode.maximumRatio, first: .leaf(leafA), second: .leaf(leafB))
        #expect(node.normalized() == expected)
    }

    @Test func removingWindowDropsWindowAndClearsKeyWindowID() {
        let doc = makeTwoWindowDocument()
        let keyID = doc.keyWindowID!
        let otherID = doc.windows.first { $0.id != keyID }!.id

        let afterRemove = doc.removingWindow(keyID)
        #expect(afterRemove.windows.count == 1)
        #expect(afterRemove.windows[0].id == otherID)
        #expect(afterRemove.keyWindowID == nil)
    }

    @Test func removingNonKeyWindowLeavesKeyWindowID() {
        let doc = makeTwoWindowDocument()
        let keyID = doc.keyWindowID!
        let otherID = doc.windows.first { $0.id != keyID }!.id

        let afterRemove = doc.removingWindow(otherID)
        #expect(afterRemove.windows.count == 1)
        #expect(afterRemove.windows[0].id == keyID)
        #expect(afterRemove.keyWindowID == keyID)
    }

    @Test func blockArchiveRetainKeepsLastMaxBlocks() {
        let blocks = (0..<250).map { i in
            SavedBlock(id: UUID(), command: "cmd\(i)", directory: "/", output: "")
        }
        let retained = BlockArchive.retain(blocks)
        #expect(retained.count == BlockArchive.maxBlocks)
        #expect(retained.first?.command == "cmd50")
        #expect(retained.last?.command == "cmd249")
    }

    @Test func blockArchiveRetainClearsOldestOutputFirst() {
        let chunkSize = BlockArchive.maxOutputBytes / 2 + 1
        let bigOutput = String(repeating: "x", count: chunkSize)
        let b1 = SavedBlock(id: UUID(), command: "cmd1", directory: "/", output: bigOutput)
        let b2 = SavedBlock(id: UUID(), command: "cmd2", directory: "/", output: bigOutput)

        let retained = BlockArchive.retain([b1, b2])
        #expect(retained.count == 2)
        #expect(retained[0].output.isEmpty)
        #expect(retained[0].command == "cmd1")
        #expect(!retained[1].output.isEmpty)
        #expect(retained[1].command == "cmd2")
    }

    @Test func cappedHistoryKeepsLastMaxHistory() {
        let commands = (0..<2500).map { "cmd\($0)" }
        let capped = BlockArchive.cappedHistory(commands)
        #expect(capped.count == BlockArchive.maxHistory)
        #expect(capped.first == "cmd500")
        #expect(capped.last == "cmd2499")
    }

    @Test func workingDirectoryNearestExistingReturnsPathWhenPresent() {
        let (path, missing) = WorkingDirectory.nearestExisting("/existing", exists: { $0 == "/existing" })
        #expect(path == "/existing")
        #expect(!missing)
    }

    @Test func workingDirectoryNearestExistingReturnsParentWhenPathAbsent() {
        let (path, missing) = WorkingDirectory.nearestExisting("/parent/child", exists: { $0 == "/parent" })
        #expect(path == "/parent")
        #expect(missing)
    }

    @Test func workingDirectoryNearestExistingReturnsDriveRootWhenNothingMatches() {
        let (path, missing) = WorkingDirectory.nearestExisting("/a/b/c", exists: { _ in false })
        #expect(path == "/")
        #expect(missing)
    }

    @Test func workingDirectoryNearestExistingGoneChildReturnsGone() {
        let (path, missing) = WorkingDirectory.nearestExisting("/gone/child", exists: { $0 == "/gone" })
        #expect(path == "/gone")
        #expect(missing)
    }

    @Test func restoreLaunchEnabledNoSkipRestores() {
        let result = RestoreLaunch.decide(restoreEnabled: true, skipOnce: false)
        #expect(result.restore == true)
        #expect(result.clearSkipOnce == false)
    }

    @Test func restoreLaunchDisabledNoSkipDoesNotRestore() {
        let result = RestoreLaunch.decide(restoreEnabled: false, skipOnce: false)
        #expect(result.restore == false)
        #expect(result.clearSkipOnce == false)
    }

    @Test func restoreLaunchSkipOnceWinsEvenWhenEnabled() {
        let result = RestoreLaunch.decide(restoreEnabled: true, skipOnce: true)
        #expect(result.restore == false)
        #expect(result.clearSkipOnce == true)
    }

    @Test func trailingDebounceDoesNotFireAtNoteTime() {
        let t = Date()
        var d = TrailingDebounce(delay: 1.0)
        d.note(at: t)
        let fired = d.consumeIfDue(at: t)
        #expect(!fired)
    }

    @Test func trailingDebounceFiresAtDeadlineAndClearsOnce() {
        let t = Date()
        var d = TrailingDebounce(delay: 1.0)
        d.note(at: t)
        let fired = d.consumeIfDue(at: t.addingTimeInterval(1.0))
        let firedAgain = d.consumeIfDue(at: t.addingTimeInterval(1.0))
        #expect(fired)
        #expect(!firedAgain)
    }

    @Test func trailingDebounceSecondNoteMovesDeadlineLater() {
        let t = Date()
        var d = TrailingDebounce(delay: 1.0)
        d.note(at: t)
        d.note(at: t.addingTimeInterval(0.5))
        let early = d.consumeIfDue(at: t.addingTimeInterval(1.0))
        let later = d.consumeIfDue(at: t.addingTimeInterval(1.5))
        #expect(!early)
        #expect(later)
    }

    @Test func workspaceStoreRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(root: tmp)

        let doc = makeTwoWindowDocument()
        try store.save(doc)
        let loaded = try store.load()
        #expect(loaded == doc)

        let paneID = UUID()
        let blocks = [
            SavedBlock(id: UUID(), command: "ls", directory: "/tmp", exitCode: 0, output: "file1"),
            SavedBlock(id: UUID(), command: "pwd", directory: "/tmp", output: "/tmp"),
        ]
        try store.save(blocks, for: paneID)
        #expect(store.loadBlocks(for: paneID) == blocks)

        #expect(store.loadBlocks(for: UUID()) == [])

        let blocksDir = tmp.appendingPathComponent("blocks")
        let badPaneID = UUID()
        let badURL = blocksDir.appendingPathComponent(badPaneID.uuidString + ".json")
        try "not json".write(to: badURL, atomically: true, encoding: .utf8)
        #expect(store.loadBlocks(for: badPaneID) == [])

        let windowToRemove = doc.windows[0].id
        try store.removeWindow(windowToRemove)
        let afterRemove = try store.load()
        #expect(afterRemove?.windows.contains { $0.id == windowToRemove } == false)
        #expect(afterRemove?.windows.count == 1)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func savedLayoutFileHasCorrectPermissionsAndExcludedFromBackup() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(root: tmp)

        let doc = makeTwoWindowDocument()
        try store.save(doc)

        let layoutURL = tmp.appendingPathComponent("layout.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: layoutURL.path)
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600)

        let rv = try layoutURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(rv.isExcludedFromBackup == true)
    }

    @Test func phoneWorkspaceRoundTrips() throws {
        let macSession = PhoneSession(id: UUID(), kind: .mac(sessionID: UUID(), macID: UUID()))
        let sshSession = PhoneSession(id: UUID(), kind: .ssh(hostID: UUID()))
        let workspace = PhoneWorkspace(sessions: [macSession, sshSession])

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(PhoneWorkspace.self, from: data)
        #expect(decoded == workspace)
    }
}
