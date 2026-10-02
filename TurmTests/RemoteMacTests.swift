import Foundation
import Testing
import TurmCore
@testable import Turm

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func isolatedKeychain() -> CompanionKeychain {
    CompanionKeychain(role: .phone, service: "app.turm.companion.tests." + UUID().uuidString)
}

private func peerRecord(_ id: UUID, _ name: String) -> CompanionPeerRecord {
    CompanionPeerRecord(id: id, name: name, key: CompanionCrypto.generateSecret())
}

@MainActor
@Suite(.serialized)
struct RemotePeersMergeTests {
    @Test func phoneOnlyDeviceBecomesRowThatCanControlThisMac() throws {
        let id = UUID()
        let rows = RemotePeers.merge(devices: [peerRecord(id, "Zak's iPhone")], macs: [(id: UUID, name: String)]())
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == id)
        #expect(row.name == "Zak's iPhone")
        #expect(row.canControlThisMac?.id == id)
        #expect(row.controlledByThisMac == nil)
    }

    @Test func macOnlyRecordBecomesRowControlledByThisMac() throws {
        let id = UUID()
        let rows = RemotePeers.merge(devices: [], macs: [(id: id, name: "Studio")])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == id)
        #expect(row.name == "Studio")
        #expect(row.canControlThisMac == nil)
    }

    @Test func sameIDOnBothSidesCollapsesIntoOneRowWithBothSidesSet() throws {
        let id = UUID()
        let device = peerRecord(id, "Studio device")
        let rows = RemotePeers.merge(devices: [device], macs: [(id: id, name: "Studio")])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.canControlThisMac == device)
    }

    @Test func clientSideMacNameWinsOverDeviceName() throws {
        let id = UUID()
        let rows = RemotePeers.merge(devices: [peerRecord(id, "Device Name")], macs: [(id: id, name: "Mac Name")])
        #expect(try #require(rows.first).name == "Mac Name")
    }

    @Test func emptyClientNameFallsBackToDeviceName() throws {
        let id = UUID()
        let rows = RemotePeers.merge(devices: [peerRecord(id, "Device Name")], macs: [(id: id, name: "")])
        #expect(try #require(rows.first).name == "Device Name")
    }

    @Test func distinctIDsWithTheSameNameStaySeparate() {
        let rows = RemotePeers.merge(devices: [peerRecord(UUID(), "Same")], macs: [(id: UUID(), name: "Same")])
        #expect(rows.count == 2)
        #expect(rows.filter { $0.canControlThisMac != nil }.count == 1)
    }

    @Test func rowsSortWithNumericAwareLocalizedCompare() {
        let macs: [(id: UUID, name: String)] = [(UUID(), "Mac 10"), (UUID(), "Mac 2"), (UUID(), "Mac 1")]
        let rows = RemotePeers.merge(devices: [], macs: macs)
        #expect(rows.map(\.name) == ["Mac 1", "Mac 2", "Mac 10"])
    }

    @Test func connectionOverloadAttachesTheConnectionToItsRow() throws {
        let keychain = isolatedKeychain()
        let both = UUID()
        let macOnly = UUID()
        let connectionBoth = RemoteMacConnection(record: peerRecord(both, "Both"), keychain: keychain)
        let connectionOnly = RemoteMacConnection(record: peerRecord(macOnly, "Only"), keychain: keychain)
        let rows = RemotePeers.merge(devices: [peerRecord(both, "Both device")], macs: [connectionBoth, connectionOnly])
        #expect(rows.count == 2)
        let bothRow = try #require(rows.first { $0.id == both })
        let onlyRow = try #require(rows.first { $0.id == macOnly })
        #expect(bothRow.controlledByThisMac === connectionBoth)
        #expect(bothRow.canControlThisMac != nil)
        #expect(onlyRow.controlledByThisMac === connectionOnly)
        #expect(onlyRow.canControlThisMac == nil)
    }
}

@MainActor
@Suite(.serialized)
struct RemoteMacPairingTests {
    private func link(macID: UUID = UUID(), expires: Date = Date().addingTimeInterval(600)) throws -> String {
        let payload = PairingPayload(
            macID: macID, macName: "Other", hosts: ["192.0.2.1"], port: 7337,
            secret: CompanionCrypto.generateSecret(), expires: expires
        )
        return try #require(payload.url).absoluteString
    }

    private func failure(_ pairing: RemoteMacPairing) -> String? {
        if case .failed(let text) = pairing.state { return text }
        return nil
    }

    @Test func garbageTextIsNotAPairingLink() {
        let pairing = RemoteMacPairing()
        pairing.pair(link: "hello there", manager: RemoteMacManager(keychain: isolatedKeychain()))
        #expect(failure(pairing)?.contains("not a Turm pairing link") == true)
        #expect(!pairing.isWorking)
    }

    @Test func nonPairURLIsRejected() {
        let pairing = RemoteMacPairing()
        pairing.pair(link: "https://example.com/pair?m=x", manager: RemoteMacManager(keychain: isolatedKeychain()))
        #expect(failure(pairing)?.contains("not a Turm pairing link") == true)
    }

    @Test func expiredLinkFailsAsExpired() throws {
        let pairing = RemoteMacPairing()
        let expired = try link(expires: Date().addingTimeInterval(-60))
        pairing.pair(link: expired, manager: RemoteMacManager(keychain: isolatedKeychain()))
        #expect(failure(pairing)?.contains("expired") == true)
        #expect(!pairing.isWorking)
    }

    @Test func linkToThisMacFailsWithoutConnecting() throws {
        let pairing = RemoteMacPairing()
        let manager = RemoteMacManager(keychain: isolatedKeychain())
        pairing.pair(link: try link(macID: RemoteMacIdentity.id), manager: manager)
        #expect(pairing.state == .failed("That is this Mac."))
        #expect(manager.connections.isEmpty)
    }

    @Test func surroundingWhitespaceInALinkIsTolerated() throws {
        let pairing = RemoteMacPairing()
        let text = "  \n" + (try link(macID: RemoteMacIdentity.id)) + "\n "
        pairing.pair(link: text, manager: RemoteMacManager(keychain: isolatedKeychain()))
        #expect(pairing.state == .failed("That is this Mac."))
    }

    @Test func selfCheckComesBeforeExpiryCheck() throws {
        let pairing = RemoteMacPairing()
        let text = try link(macID: RemoteMacIdentity.id, expires: Date().addingTimeInterval(-60))
        pairing.pair(link: text, manager: RemoteMacManager(keychain: isolatedKeychain()))
        #expect(pairing.state == .failed("That is this Mac."))
    }

    @Test func manualPairingValidatesAddressAndCodeBeforeConnecting() {
        let pairing = RemoteMacPairing()
        let manager = RemoteMacManager(keychain: isolatedKeychain())
        pairing.pair(host: "   ", port: 7337, code: "12345678", manager: manager)
        #expect(failure(pairing)?.contains("address and port") == true)
        pairing.pair(host: "192.0.2.1", port: 7337, code: "12", manager: manager)
        #expect(failure(pairing)?.contains("8-digit code") == true)
        #expect(!pairing.isWorking)
    }

    @Test func rejectAndResetOnlyActWhenIdle() {
        let pairing = RemoteMacPairing()
        pairing.reject("boom")
        #expect(pairing.state == .failed("boom"))
        pairing.reset()
        #expect(pairing.state == .idle)
    }
}

@MainActor
@Suite(.serialized)
struct RemoteMacManagerTests {
    @Test func pairingThisMacItselfIsIgnored() {
        let keychain = isolatedKeychain()
        let manager = RemoteMacManager(keychain: keychain)
        manager.addPaired(macID: RemoteMacIdentity.id, name: "Me", key: CompanionCrypto.generateSecret(), hosts: [], port: 7337)
        #expect(manager.connections.isEmpty)
        #expect(keychain.all().isEmpty)
    }

    @Test func addPairedStoresRecordAndForgetRemovesConnectionAndRecord() throws {
        let keychain = isolatedKeychain()
        let manager = RemoteMacManager(keychain: keychain)
        let id = UUID()
        let key = CompanionCrypto.generateSecret()
        manager.addPaired(macID: id, name: "Studio", key: key, hosts: [], port: 7337)
        defer { manager.forget(id) }

        #expect(manager.connections.map(\.id) == [id])
        #expect(manager.connection(for: id.uuidString)?.name == "Studio")
        let stored = try #require(keychain.record(for: id))
        #expect(stored.name == "Studio")
        #expect(stored.key == key)
        #expect(manager.macs.map(\.id) == [id.uuidString])

        manager.selectedID = id.uuidString
        manager.forget(id)
        #expect(manager.connections.isEmpty)
        #expect(manager.connection(for: id.uuidString) == nil)
        #expect(keychain.record(for: id) == nil)
        #expect(manager.selectedID == nil)
    }

    @Test func forgetKeepsOtherMacsAndSelection() {
        let keychain = isolatedKeychain()
        let manager = RemoteMacManager(keychain: keychain)
        let kept = UUID()
        let dropped = UUID()
        manager.addPaired(macID: kept, name: "Kept", key: CompanionCrypto.generateSecret(), hosts: [], port: 7337)
        manager.addPaired(macID: dropped, name: "Dropped", key: CompanionCrypto.generateSecret(), hosts: [], port: 7337)
        defer { manager.forget(kept) }
        manager.selectedID = kept.uuidString
        manager.forget(dropped)
        #expect(manager.connections.map(\.id) == [kept])
        #expect(keychain.record(for: kept) != nil)
        #expect(keychain.record(for: dropped) == nil)
        #expect(manager.selectedID == kept.uuidString)
    }

    @Test func pairingAgainReplacesTheExistingRecord() throws {
        let keychain = isolatedKeychain()
        let manager = RemoteMacManager(keychain: keychain)
        let id = UUID()
        manager.addPaired(macID: id, name: "Old", key: CompanionCrypto.generateSecret(), hosts: [], port: 7337)
        defer { manager.forget(id) }
        let newKey = CompanionCrypto.generateSecret()
        manager.addPaired(macID: id, name: "New", key: newKey, hosts: [], port: 7337)
        #expect(manager.connections.count == 1)
        #expect(manager.connections.first?.name == "New")
        #expect(try #require(keychain.record(for: id)).key == newKey)
    }

    @Test func managerLoadsConnectionsFromTheKeychain() {
        let keychain = isolatedKeychain()
        let id = UUID()
        try? keychain.save(peerRecord(id, "Saved"))
        defer { keychain.removeAll() }
        let manager = RemoteMacManager(keychain: keychain)
        #expect(manager.connections.map(\.id) == [id])
        #expect(manager.connections.first?.state == .offline)
    }
}

@MainActor
@Suite(.serialized)
struct RemoteMacShellTests {
    private let shellID = UUID()

    private func summary(_ command: String, text: String = "", exit: Int32? = 0) -> BlockSummary {
        BlockSummary(id: UUID(), command: command, location: "~", exitCode: exit, text: text, directory: "/tmp")
    }

    @Test func snapshotBuildsFinishedHistoryAndARunningBlock() async throws {
        let shell = RemoteMacShell(id: shellID)
        let running = RunningBlock(id: UUID(), command: "sleep 9", location: "~", bytes: Data("tick\r\n".utf8), directory: "/tmp")
        let history = [summary("ls", text: "a.txt\nb.txt\n", exit: 0), summary("false", text: "", exit: 1)]
        shell.handle(.snapshot(id: shellID, cols: 100, rows: 30, history: history, running: running))

        #expect(shell.blocks.count == 3)
        #expect(shell.blocks.map(\.command) == ["ls", "false", "sleep 9"])
        #expect(shell.blocks.map(\.isRunning) == [false, false, true])
        #expect(shell.blocks[0].exitCode == 0)
        #expect(shell.blocks[1].exitCode == 1)
        #expect(shell.blocks[1].failed)
        #expect(shell.blocks[0].plainOutput.contains("a.txt"))
        #expect(shell.blocks[0].plainOutput.contains("b.txt"))
        #expect(shell.runningBlock === shell.blocks[2])
        #expect(shell.runningBlock?.plainOutput.contains("tick") == true)
        #expect(shell.phase == .running)
        #expect(shell.macColumns == 100)
        #expect(shell.macRows == 30)
        #expect(shell.hasContent)
    }

    @Test func snapshotWithoutRunningBlockIsReady() {
        let shell = RemoteMacShell(id: shellID)
        shell.handle(.phase(id: shellID, phase: .running, directory: "/"))
        #expect(shell.phase == .running)
        shell.handle(.snapshot(id: shellID, cols: 80, rows: 24, history: [summary("pwd")], running: nil))
        #expect(shell.phase == .ready)
        #expect(shell.runningBlock == nil)
        #expect(shell.blocks.count == 1)
    }

    @Test func commandsListIsNewestFirstWithoutDuplicatesOrEmpties() {
        let shell = RemoteMacShell(id: shellID)
        let history = [summary("ls"), summary("pwd"), summary(""), summary("ls"), summary("echo hi")]
        shell.handle(.snapshot(id: shellID, cols: 80, rows: 24, history: history, running: nil))
        #expect(shell.commands == ["echo hi", "ls", "pwd"])
    }

    @Test func startedOutputAndFinishedDriveABlockThroughItsLifecycle() async throws {
        let shell = RemoteMacShell(id: shellID)
        shell.handle(.snapshot(id: shellID, cols: 80, rows: 24, history: [], running: nil))
        let blockID = UUID()

        shell.handle(.blockStarted(id: shellID, blockID: blockID, command: "echo hello", location: "~", directory: "/tmp", git: nil, host: nil))
        #expect(shell.blocks.count == 1)
        #expect(shell.blocks[0].command == "echo hello")
        #expect(shell.blocks[0].isRunning)
        #expect(shell.phase == .running)

        shell.handle(.output(id: shellID, blockID: blockID, bytes: Data("hello\r\n".utf8)))
        let shown = await waitUntil { shell.blocks[0].plainOutput.contains("hello") }
        #expect(shown)
        #expect(shell.blocks[0].isRunning)

        shell.handle(.blockFinished(id: shellID, blockID: blockID, exitCode: 3))
        #expect(!shell.blocks[0].isRunning)
        #expect(shell.blocks[0].exitCode == 3)
        #expect(shell.blocks[0].failed)
        #expect(shell.blocks[0].plainOutput.contains("hello"))
        #expect(shell.runningBlock == nil)
        #expect(shell.blocks[0].duration != nil)

        shell.handle(.phase(id: shellID, phase: .ready, directory: "/tmp"))
        #expect(shell.phase == .ready)
    }

    @Test func outputAfterFinishAndForUnknownBlocksIsDropped() async {
        let shell = RemoteMacShell(id: shellID)
        let blockID = UUID()
        shell.handle(.blockStarted(id: shellID, blockID: blockID, command: "true", location: "~", directory: "/", git: nil, host: nil))
        shell.handle(.blockFinished(id: shellID, blockID: blockID, exitCode: 0))
        shell.handle(.output(id: shellID, blockID: blockID, bytes: Data("late".utf8)))
        shell.handle(.blockFinished(id: shellID, blockID: UUID(), exitCode: 9))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(shell.blocks.count == 1)
        #expect(shell.blocks[0].exitCode == 0)
        #expect(!shell.blocks[0].plainOutput.contains("late"))
    }

    @Test func startingANewBlockFinishesTheStillRunningOneWithoutAnExitCode() {
        let shell = RemoteMacShell(id: shellID)
        let first = UUID()
        let second = UUID()
        shell.handle(.blockStarted(id: shellID, blockID: first, command: "one", location: "~", directory: "/", git: nil, host: nil))
        shell.handle(.blockStarted(id: shellID, blockID: second, command: "two", location: "~", directory: "/", git: nil, host: nil))
        #expect(shell.blocks.map(\.command) == ["one", "two"])
        #expect(!shell.blocks[0].isRunning)
        #expect(shell.blocks[0].exitCode == nil)
        #expect(shell.blocks[1].isRunning)
    }

    @Test func repeatedBlockStartedForTheSameBlockIsIgnored() {
        let shell = RemoteMacShell(id: shellID)
        let blockID = UUID()
        shell.handle(.blockStarted(id: shellID, blockID: blockID, command: "once", location: "~", directory: "/", git: nil, host: nil))
        shell.handle(.blockStarted(id: shellID, blockID: blockID, command: "once", location: "~", directory: "/", git: nil, host: nil))
        #expect(shell.blocks.count == 1)
    }

    @Test func leavingAlternateScreenAfterAFullScreenResizeClearsFullScreenAndKeepsOriginalSize() throws {
        let shell = RemoteMacShell(id: shellID)
        let connection = RemoteMacConnection(record: peerRecord(UUID(), "Studio"), keychain: isolatedKeychain())
        let session = RemoteMacSession(connection: connection, shell: shell)
        session.setViewport(CGSize(width: 800, height: 600))
        session.setFitsWindow(true)
        shell.handle(.snapshot(id: shellID, cols: 80, rows: 24, history: [], running: nil))
        let blockID = UUID()
        shell.handle(.blockStarted(id: shellID, blockID: blockID, command: "vim", location: "~", directory: "/", git: nil, host: nil))
        shell.handle(.output(id: shellID, blockID: blockID, bytes: Data("\u{1b}[?1049hhello".utf8)))
        let host = try #require(shell.fullScreen)
        host.onResize(120, 40)

        shell.handle(.blockFinished(id: shellID, blockID: blockID, exitCode: 0))

        #expect(shell.fullScreen == nil)
        #expect(shell.originalSize?.cols == 80)
        #expect(shell.originalSize?.rows == 24)
        #expect(shell.fitCount == 1)
        withExtendedLifetime(session) {}
    }

    @Test func endedMarksTheShellEnded() {
        let shell = RemoteMacShell(id: shellID)
        #expect(!shell.hasEnded)
        shell.ended()
        #expect(shell.hasEnded)
    }

    @Test func sessionClosedMessageDoesNotChangeShellState() {
        let shell = RemoteMacShell(id: shellID)
        shell.handle(.snapshot(id: shellID, cols: 80, rows: 24, history: [summary("ls")], running: nil))
        shell.handle(.sessionClosed(id: shellID))
        #expect(shell.blocks.count == 1)
        #expect(!shell.hasEnded)
    }
}
