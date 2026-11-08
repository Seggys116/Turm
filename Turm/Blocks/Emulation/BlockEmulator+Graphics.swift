import AppKit
import Foundation
import SwiftTerm
import TurmCore

extension BlockEmulator {
    var cursorRow: Int {
        terminal.buffer.yDisp + terminal.buffer.y + terminal.buffer.totalLinesTrimmed
    }

    var normalStore: KittyImageStore {
        engine.store
    }

    var altStore: KittyImageStore {
        engine.alternateStore
    }

    private var activeStore: KittyImageStore {
        engine.activeStore
    }

    var images: [InlineImage] {
        let kitty = activeStore.images.map(kittyImage)
        return terminal.isCurrentBufferAlternate ? kitty : inlineImages + kitty
    }

    var virtualPlacements: [InlineImage] {
        activeStore.virtualPlacements.map(kittyImage)
    }

    var sources: [UInt32: KittyAnimation] {
        activeStore.sources
    }

    var placedIDs: Set<UInt32> {
        activeStore.placedIDs()
    }

    var usedStorage: Int {
        activeStore.usedStorage
    }

    var cacheSize: Int {
        activeStore.cacheSize
    }

    var storageLimit: Int {
        get { activeStore.storageLimit }
        set { activeStore.storageLimit = newValue }
    }

    func kittyImage(_ placement: GraphicsPlacement) -> InlineImage {
        InlineImage(placement: placement, requested: placementSizes[placement.id] ?? (0, 0))
    }

    func feedGraphics(_ apc: ArraySlice<UInt8>, _ command: KittyCommand) {
        // placements land on the last chunk, but take their requested size from the first
        if command.action != nil || !graphicsContinues {
            graphicsSizing = (max(command.columns ?? 0, 0), max(command.rows ?? 0, 0))
        }
        graphicsContinues = command.more
        let known = Set(activeStore.images.map(\.id))
        engine.handle(apc, host: graphicsHost)
        for placement in activeStore.images where !known.contains(placement.id) {
            placementSizes[placement.id] = graphicsSizing
        }
        let live = normalStore.images.count + altStore.images.count
        guard placementSizes.count > live * 2 + 64 else { return }
        let kept = Set(normalStore.images.map(\.id)).union(altStore.images.map(\.id))
        placementSizes = placementSizes.filter { kept.contains($0.key) }
    }

    /// Drops the rest of a graphics command that outgrew the hold, up to its terminator.
    func skipGraphics(_ bytes: [UInt8]) -> [UInt8]? {
        let bytes = skipCarry + bytes
        skipCarry = []
        guard let end = KittyGraphicsScanner.terminator(in: bytes, from: 0) else {
            if bytes.last == 0x1B { skipCarry = [0x1B] }
            return nil
        }
        skippingGraphics = false
        return Array(bytes[(bytes[end] == 0x1B ? end + 2 : end + 1)...])
    }

    func clearGraphics(_ scope: KittyGraphicsScanner.ClearScope) {
        if scope == .scrollback {
            pushScreenIntoScrollback()
            terminal.feed(byteArray: Array("\u{1B}[2J".utf8))
        }
        engine.clear(scope, host: graphicsHost)
        guard scope == .reset || !terminal.isCurrentBufferAlternate else { return }
        if scope == .everything {
            inlineImages.removeAll()
        } else {
            let top = terminal.buffer.yDisp + terminal.buffer.totalLinesTrimmed
            inlineImages.removeAll { $0.anchor + max($0.rowSpan, 1) > top }
        }
    }

    private func pushScreenIntoScrollback() {
        guard !terminal.isCurrentBufferAlternate else { return }
        func blank(_ row: Int) -> Bool {
            guard let line = terminal.getLine(row: row) else { return true }
            for column in 0..<line.count {
                let character = terminal.getCharacter(for: line[column])
                if character != " " && character != "\u{0}" { return false }
            }
            return true
        }
        var count = terminal.rows
        while count > 0, blank(count - 1) { count -= 1 }
        guard count > 0 else { return }
        let sequence = "\u{1B}7\u{1B}[\(terminal.rows);1H" + String(repeating: "\n", count: count) + "\u{1B}8"
        terminal.feed(byteArray: Array(sequence.utf8))
    }

    func pruneScrolledOff() {
        let trimmed = terminal.buffer.totalLinesTrimmed
        guard trimmed > 0 else { return }
        engine.pruneScrolledOff(trimmed: trimmed)
        guard !terminal.isCurrentBufferAlternate else { return }
        inlineImages.removeAll { $0.rowSpan > 0 && $0.anchor + $0.rowSpan <= trimmed }
    }

    /// Kitty placements of the main screen from `top` down, with placeholder tiles kept apart.
    func kittyPlacements(from top: Int) -> (images: [InlineImage], tiles: [InlineImage]) {
        guard !terminal.isCurrentBufferAlternate else {
            // the engine lays out the active screen only; the main screen's cells are not on show here
            let store = normalStore
            let placed = store.images.compactMap { image -> InlineImage? in
                guard image.rowSpan > 0, let origin = store.images.origin(of: image) else { return nil }
                var moved = image
                moved.origin = origin
                return kittyImage(moved)
            }
            return (placed, [])
        }
        var images: [InlineImage] = []
        var tiles: [InlineImage] = []
        for placement in engine.placements(visible: top..<Int.max, host: graphicsHost) {
            if placement.tile == nil {
                images.append(kittyImage(placement))
            } else {
                tiles.append(kittyImage(placement))
            }
        }
        return (images, tiles)
    }

    func origin(of image: InlineImage) -> (row: Int, column: Int)? {
        let store = normalStore
        guard let placement = store.images.first(where: { $0.id == image.id }) else {
            return image.parent == nil ? (image.anchor, image.column) : nil
        }
        var virtual: [KittyKey: GridPoint] = [:]
        if !store.virtualPlacements.isEmpty {
            let cells = KittyPlaceholders.decode(graphicsHost.placeholderCells(rows: 0..<Int.max))
            virtual = KittyPlaceholders.tiles(of: cells, placements: store.virtualPlacements).origins
        }
        return store.images.origin(of: placement, virtual: virtual).map { ($0.row, $0.column) }
    }
}
