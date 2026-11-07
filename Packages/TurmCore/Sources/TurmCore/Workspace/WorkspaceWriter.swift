import Foundation

public nonisolated struct SaveTracker: Sendable, Equatable {
    public struct Batch: Sendable, Equatable {
        public var layout: Bool
        public var blocks: Bool
    }

    public var delay: TimeInterval
    public var maxWait: TimeInterval
    private var layoutDirty = false
    private var blocksDirty = false
    private var firstMark: Date?
    private var lastMark: Date?

    public init(delay: TimeInterval = 1.5, maxWait: TimeInterval = 10) {
        self.delay = delay
        self.maxWait = maxWait
    }

    public var isPending: Bool { firstMark != nil }

    public var fireTime: Date? {
        guard let firstMark, let lastMark else { return nil }
        return min(lastMark.addingTimeInterval(delay), firstMark.addingTimeInterval(maxWait))
    }

    public mutating func markLayout(at now: Date) {
        layoutDirty = true
        stamp(now)
    }

    public mutating func markBlocks(at now: Date) {
        blocksDirty = true
        stamp(now)
    }

    public mutating func consumeIfDue(at now: Date) -> Batch? {
        guard let fire = fireTime, now >= fire else { return nil }
        return take()
    }

    public mutating func take() -> Batch? {
        guard isPending else { return nil }
        let batch = Batch(layout: layoutDirty, blocks: blocksDirty)
        cancel()
        return batch
    }

    public mutating func cancel() {
        layoutDirty = false
        blocksDirty = false
        firstMark = nil
        lastMark = nil
    }

    private mutating func stamp(_ now: Date) {
        if firstMark == nil { firstMark = now }
        lastMark = now
    }
}

public nonisolated struct BlockWriteLedger: Sendable, Equatable {
    private var written: [UUID: Int] = [:]

    public init() {}

    public static func signature(of ids: [UUID]) -> Int {
        var hasher = Hasher()
        hasher.combine(ids.count)
        for id in ids { hasher.combine(id) }
        return hasher.finalize()
    }

    /// Returns the panes whose signature differs from the last one claimed and records the new ones.
    public mutating func claim(_ current: [UUID: Int]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (pane, value) in current where written[pane] != value {
            changed.insert(pane)
            written[pane] = value
        }
        return changed
    }

    public mutating func reset() {
        written = [:]
    }
}

extension WorkspaceDocument {
    public mutating func record(_ captured: SavedWindow, isKey: Bool, space: SavedSpace?) {
        if let index = windows.firstIndex(where: { $0.id == captured.id }) {
            windows[index] = captured
        } else {
            windows.append(captured)
        }
        if isKey || keyWindowID == nil {
            keyWindowID = captured.id
        }
        guard let space else { return }
        if spaces.isEmpty, !windows.isEmpty {
            spaces = spaceCatalog
        }
        if let index = spaces.firstIndex(where: { $0.id == space.id }) {
            spaces[index] = space
        } else {
            spaces.append(space)
        }
    }

    /// Drops a scratch space, including one that was written before it was marked temporary.
    public mutating func purgeScratch(ids: Set<UUID>) -> Bool {
        let purged = discardingTemporarySpaces()
        let kept = purged.windows.filter { !ids.contains($0.id) }
        let keptSpaces = purged.spaces.filter { !ids.contains($0.id) && !ids.contains($0.session.id) }
        var key = purged.keyWindowID
        if let current = key, ids.contains(current) {
            key = keptSpaces.first?.id ?? kept.first?.id
        }
        let next = WorkspaceDocument(windows: kept, keyWindowID: key, spaces: keptSpaces)
        guard next != self else { return false }
        self = next
        return true
    }
}

public nonisolated struct LayoutStamp: Sendable, Equatable {
    public let modified: Date
    public let size: Int
}

extension WorkspaceStore {
    public func layoutStamp() -> LayoutStamp? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("layout.json").path)
        guard let modified = attributes?[.modificationDate] as? Date else { return nil }
        return LayoutStamp(modified: modified, size: (attributes?[.size] as? Int) ?? 0)
    }
}

public nonisolated final class WorkspaceWriter: @unchecked Sendable {
    public let store: WorkspaceStore
    private let queue = DispatchQueue(label: "turm.workspace.writer", qos: .utility)
    private var cached: WorkspaceDocument?
    private var stamp: LayoutStamp?
    private var hasCache = false

    public init(store: WorkspaceStore) {
        self.store = store
    }

    /// The body returns true when it changed the document and it should be written.
    public func update(
        wait: Bool, createIfMissing: Bool = false, blocks: [UUID: [SavedBlock]] = [:],
        _ body: (@Sendable (inout WorkspaceDocument) -> Bool)? = nil
    ) {
        let work: @Sendable () -> Void = { [self] in
            if let body {
                let existing = loadDocument()
                if existing != nil || createIfMissing {
                    var document = existing ?? WorkspaceDocument(windows: [], keyWindowID: nil)
                    if body(&document) { commit(document) }
                }
            }
            for (pane, saved) in blocks {
                try? store.save(saved, for: pane)
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    public func clear() {
        queue.sync {
            try? store.clear()
            hasCache = false
            cached = nil
        }
    }

    public func drain() {
        queue.sync {}
    }

    private func loadDocument() -> WorkspaceDocument? {
        let onDisk = store.layoutStamp()
        if hasCache, onDisk == stamp { return cached }
        cached = try? store.load()
        stamp = onDisk
        hasCache = true
        return cached
    }

    private func commit(_ document: WorkspaceDocument) {
        try? store.save(document)
        cached = document
        stamp = store.layoutStamp()
        hasCache = true
    }
}
