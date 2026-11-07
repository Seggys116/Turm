import Foundation
import Testing
@testable import TurmCore

struct WorkspaceWriterTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func window(_ id: UUID = UUID()) -> SavedWindow {
        SavedWindow(id: id, frame: nil, tabs: [], activeTabID: UUID(), panes: [])
    }

    private func temporaryStore() -> WorkspaceStore {
        WorkspaceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("turm-writer-\(UUID().uuidString)"))
    }

    @Test func trackerWaitsForTheTrailingDelay() {
        var tracker = SaveTracker(delay: 1.5, maxWait: 10)
        tracker.markLayout(at: start)
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(1.4)) == nil)
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(1.5)) == SaveTracker.Batch(layout: true, blocks: false))
        #expect(!tracker.isPending)
    }

    @Test func trackerCoalescesABurstIntoOneBatch() {
        var tracker = SaveTracker(delay: 1.5, maxWait: 10)
        tracker.markLayout(at: start)
        tracker.markBlocks(at: start.addingTimeInterval(1))
        tracker.markLayout(at: start.addingTimeInterval(2))
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(3)) == nil)
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(3.5)) == SaveTracker.Batch(layout: true, blocks: true))
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(9)) == nil)
    }

    @Test func trackerFiresAtMaxWaitUnderContinuousActivity() {
        var tracker = SaveTracker(delay: 1.5, maxWait: 4)
        for second in 0..<10 { tracker.markBlocks(at: start.addingTimeInterval(Double(second) * 0.5)) }
        #expect(tracker.fireTime == start.addingTimeInterval(4))
        #expect(tracker.consumeIfDue(at: start.addingTimeInterval(4)) == SaveTracker.Batch(layout: false, blocks: true))
    }

    @Test func trackerCancelDropsPendingWork() {
        var tracker = SaveTracker()
        tracker.markLayout(at: start)
        tracker.cancel()
        #expect(tracker.take() == nil)
        #expect(tracker.fireTime == nil)
    }

    @Test func trackerTakeFlushesBeforeTheDeadline() {
        var tracker = SaveTracker()
        tracker.markBlocks(at: start)
        #expect(tracker.take() == SaveTracker.Batch(layout: false, blocks: true))
    }

    @Test func ledgerReportsOnlyChangedPanes() {
        var ledger = BlockWriteLedger()
        let first = UUID()
        let second = UUID()
        let one = BlockWriteLedger.signature(of: [UUID()])
        let two = BlockWriteLedger.signature(of: [UUID(), UUID()])
        #expect(ledger.claim([first: one, second: two]) == [first, second])
        #expect(ledger.claim([first: one, second: two]).isEmpty)
        #expect(ledger.claim([first: one, second: one]) == [second])
    }

    @Test func ledgerResetForgetsWhatWasWritten() {
        var ledger = BlockWriteLedger()
        let pane = UUID()
        let signature = BlockWriteLedger.signature(of: [UUID()])
        _ = ledger.claim([pane: signature])
        ledger.reset()
        #expect(ledger.claim([pane: signature]) == [pane])
    }

    @Test func signatureTracksOrderAndCount() {
        let a = UUID()
        let b = UUID()
        #expect(BlockWriteLedger.signature(of: [a, b]) == BlockWriteLedger.signature(of: [a, b]))
        #expect(BlockWriteLedger.signature(of: [a, b]) != BlockWriteLedger.signature(of: [b, a]))
        #expect(BlockWriteLedger.signature(of: [a]) != BlockWriteLedger.signature(of: [a, b]))
    }

    @Test func recordReplacesTheWindowAndSetsKey() {
        let id = UUID()
        var document = WorkspaceDocument(windows: [window(id)], keyWindowID: nil)
        var updated = window(id)
        updated.frame = SavedFrame(x: 1, y: 2, width: 3, height: 4)
        document.record(updated, isKey: false, space: nil)
        #expect(document.windows == [updated])
        #expect(document.keyWindowID == id)
    }

    @Test func recordKeepsAnotherKeyWindowUnlessClaimed() {
        let other = window()
        let mine = window()
        var document = WorkspaceDocument(windows: [other], keyWindowID: other.id)
        document.record(mine, isKey: false, space: nil)
        #expect(document.keyWindowID == other.id)
        document.record(mine, isKey: true, space: nil)
        #expect(document.keyWindowID == mine.id)
        #expect(document.windows.count == 2)
    }

    @Test func recordAddsSpaceAndSeedsCatalogFromExistingWindows() {
        let existing = window()
        let mine = window()
        var document = WorkspaceDocument(windows: [existing], keyWindowID: nil)
        let space = SavedSpace(id: mine.id, name: "Work", symbol: "folder", session: mine)
        document.record(mine, isKey: true, space: space)
        #expect(document.spaces.count == 2)
        #expect(document.spaces.last == space)
        #expect(document.spaces.first?.id == existing.id)
    }

    @Test func purgeScratchRemovesIdsAndReportsChange() {
        let scratch = window()
        let kept = window()
        var document = WorkspaceDocument(windows: [scratch, kept], keyWindowID: scratch.id)
        let purged = document.purgeScratch(ids: [scratch.id])
        #expect(purged)
        #expect(document.windows == [kept])
        #expect(document.keyWindowID == kept.id)
        let purgedAgain = document.purgeScratch(ids: [scratch.id])
        #expect(!purgedAgain)
    }

    @Test func writerPersistsDocumentAndBlocks() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let writer = WorkspaceWriter(store: store)
        let captured = window()
        let pane = UUID()
        let block = SavedBlock(id: UUID(), command: "ls", directory: "/tmp", output: "a")
        writer.update(wait: true, createIfMissing: true, blocks: [pane: [block]]) { document in
            document.record(captured, isKey: true, space: nil)
            return true
        }
        #expect(try store.load()?.windows == [captured])
        #expect(store.loadBlocks(for: pane) == [block])
    }

    @Test func writerSkipsMissingDocumentUnlessAskedToCreate() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let writer = WorkspaceWriter(store: store)
        writer.update(wait: true) { _ in true }
        #expect(try store.load() == nil)
    }

    @Test func writerSeesDocumentChangesMadeOutsideIt() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let writer = WorkspaceWriter(store: store)
        let first = window()
        writer.update(wait: true, createIfMissing: true) { $0.record(first, isKey: true, space: nil); return true }
        let outside = window()
        try store.save(WorkspaceDocument(windows: [first, outside], keyWindowID: first.id))
        let third = window()
        writer.update(wait: true) { $0.record(third, isKey: false, space: nil); return true }
        #expect(try store.load()?.windows.map(\.id) == [first.id, outside.id, third.id])
    }

    @Test func clearWinsOverEarlierQueuedWrites() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let writer = WorkspaceWriter(store: store)
        let captured = window()
        writer.update(wait: false, createIfMissing: true) { $0.record(captured, isKey: true, space: nil); return true }
        writer.clear()
        #expect(try store.load() == nil)
        writer.update(wait: true, createIfMissing: true) { $0.record(captured, isKey: true, space: nil); return true }
        #expect(try store.load()?.windows == [captured])
    }
}
